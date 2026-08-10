//
//  ModernXabberInputView.swift
//  xabber
//
//  Created by Игорь Болдин on 16.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import AVFoundation

protocol ChatViewMessagesPanelDelegate: AnyObject {
    func messagesPanelOnClose()
    func messagesPanelOnIndicatorTouch()
}

protocol XabberInputBarDelegate: AnyObject {
    func sendButtonTouchUp(with text: String)
    func sendButtonLongPressMenuRequested(sourceView: UIView, payload: ComposerMessagePayload)
    func scheduledMessagesButtonTouchUp()
    func attachmentButtonTouchUp()
    func onAfterburnButtonTouchUp()
    func onHeightChanged(to height: CGFloat, bar barHeight: CGFloat)
    func onCheckDevices()
    func onCheckContactDevices()
    func onUpdateSignature()
    func onIdentityVerification()
    func onTextDidChange(to text: String?)
    func onAudioMessageStartRecord(sessionID: UUID)
    func onAudioMessageDidCancel(sessionID: UUID)
    func onAudioMessageDidFinish(sessionID: UUID, intent: VoiceRecordingFinishIntent)
    func onAudioMessagePreviewSend(sessionID: UUID)
    func onAudioMessagePreviewDelete(sessionID: UUID)
    func recordAndPlayPanelPlayButtonTouchUp(sessionID: UUID)
    func didStopPlayingAudio()
    func didSetAudioPositionBar(percentage: Float) -> TimeInterval
}

struct ComposerTypingVisualState: Equatable {
    let actionMode: ModernXabberInputView.ComposerActionMode
    let timerHidden: Bool
    let scheduledMessagesVisible: Bool
}

struct ComposerTypingUpdateDecision: Equatable {
    let shouldInvalidateIntrinsicContentSize: Bool
    let shouldUpdateControls: Bool
}

enum ComposerTypingUpdatePolicy {
    static func visualState(
        inputState: ModernXabberInputView.InputBarState,
        rawText: String,
        trimmedText: String,
        shouldHideTimer: Bool,
        hasScheduledMessages: Bool
    ) -> ComposerTypingVisualState {
        let actionMode: ModernXabberInputView.ComposerActionMode = trimmedText.isNotEmpty ? .textSend : .record
        let timerHidden: Bool
        if inputState == .normal {
            timerHidden = rawText.isEmpty ? shouldHideTimer : true
        } else {
            timerHidden = true
        }
        let scheduledMessagesVisible = ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: inputState,
            body: rawText,
            hasScheduledMessages: hasScheduledMessages
        )

        return ComposerTypingVisualState(
            actionMode: actionMode,
            timerHidden: timerHidden,
            scheduledMessagesVisible: scheduledMessagesVisible
        )
    }

    static func decision(
        force: Bool,
        requiredContentHeight: CGFloat,
        currentContentHeight: CGFloat,
        previousVisualState: ComposerTypingVisualState,
        nextVisualState: ComposerTypingVisualState
    ) -> ComposerTypingUpdateDecision {
        ComposerTypingUpdateDecision(
            shouldInvalidateIntrinsicContentSize: force || abs(requiredContentHeight - currentContentHeight) > 0.5,
            shouldUpdateControls: force || previousVisualState != nextVisualState
        )
    }
}

struct RecordingCancelHintVisualState: Equatable {
    let originX: CGFloat
    let alpha: CGFloat
}

enum RecordingCancelHintVisualPolicy {
    static let minimumOriginX: CGFloat = 106
    private static let fadeStartDistance: CGFloat = 12
    private static let cancellationDistance: CGFloat = 120

    static func visualState(translationX: CGFloat) -> RecordingCancelHintVisualState {
        let leftDragDistance = min(max(-translationX, 0), cancellationDistance)
        let fadeDistance = max(cancellationDistance - fadeStartDistance, 1)
        let fadeProgress = min(
            max((leftDragDistance - fadeStartDistance) / fadeDistance, 0),
            1
        )
        return RecordingCancelHintVisualState(
            originX: minimumOriginX,
            alpha: 1 - fadeProgress
        )
    }
}

enum ComposerRecordingGeometryResetPolicy {
    static func shouldReset(previousWidth: CGFloat, nextWidth: CGFloat) -> Bool {
        guard previousWidth.isFinite else { return true }
        return abs(previousWidth - nextWidth) > 0.5
    }
}

class ModernXabberInputView: UIView {
    static let edgeHorizontalInset: CGFloat = NativeGlassBarStyle.horizontalInset
    static let minimumComposerHeight: CGFloat = NativeGlassBarStyle.minimumHeight
    static let defaultBarHeight: CGFloat = NativeGlassBarStyle.minimumHeight + NativeGlassBarStyle.bottomOffset

    static func resolvedContainerHeight(
        barHeight: CGFloat,
        keyboardHeight: CGFloat,
        topInset: CGFloat,
        bottomSafeAreaInset: CGFloat,
        includeBottomSafeAreaWhenKeyboardHidden: Bool
    ) -> CGFloat {
        let safeAreaHeight = keyboardHeight == 0 && includeBottomSafeAreaWhenKeyboardHidden
            ? bottomSafeAreaInset
            : 0
        return barHeight + keyboardHeight + topInset + safeAreaHeight
    }

    private enum LiquidGlassMetrics {
        static let composerHorizontalInset: CGFloat = 0
        static let composerVerticalInset: CGFloat = 0
        static let composerCornerRadius: CGFloat = NativeGlassBarStyle.cornerRadius
        static let buttonSize: CGFloat = NativeGlassBarStyle.buttonSize
        static let buttonSpacing: CGFloat = NativeGlassBarStyle.interItemSpacing
        static let textVerticalInset: CGFloat = 4
        static let textHorizontalInset: CGFloat = NativeGlassBarStyle.contentInset
        static let verticalReserve: CGFloat = NativeGlassBarStyle.bottomOffset
        static let contentTopOffset: CGFloat = 0
        static let previewHorizontalInset: CGFloat = 8
        static let previewCornerRadius: CGFloat = 20
        static let contextPreviewHeight: CGFloat = 44
        static let contextPreviewComposerGap: CGFloat = 4
        static let contextPreviewReservedHeight: CGFloat = contextPreviewHeight + contextPreviewComposerGap
        static let recordingLockButtonVerticalGap: CGFloat = 52
        static let scheduledMessagesButtonWidth: CGFloat = 44
        static let scheduledMessagesButtonTextGap: CGFloat = 0
    }

    private enum RecordingGlowMetrics {
        static let envelopeSize: CGFloat = 128
        static let coreSize: CGFloat = 72
        static let maximumCoreSize: CGFloat = 88
        static let haloSize: CGFloat = 88
        static let maximumHaloSize: CGFloat = 128
        static let minimumHaloAlpha: CGFloat = 0.12
        static let maximumHaloAlpha: CGFloat = 0.28
        static let riseSmoothing: CGFloat = 0.36
        static let fallSmoothing: CGFloat = 0.22
        static let animationDuration: TimeInterval = 0.08
    }

    private static func makeGlassEffect(
        role: XabberGlassStyle.SurfaceRole = .bar,
        interactive: Bool = false,
        prefersNativeGlass: Bool = true,
        nativeGlassStyle: XabberGlassStyle.GlassEffectStyle? = nil
    ) -> UIVisualEffect {
        XabberGlassStyle.makeEffect(
            role: role,
            interactive: interactive,
            prefersNativeGlass: prefersNativeGlass,
            nativeGlassStyle: nativeGlassStyle
        )
    }

    private static func makeGlassEffectView(
        role: XabberGlassStyle.SurfaceRole = .bar,
        interactive: Bool = false,
        prefersNativeGlass: Bool = true,
        nativeGlassStyle: XabberGlassStyle.GlassEffectStyle? = nil
    ) -> UIVisualEffectView {
        let view = UIVisualEffectView(
            effect: makeGlassEffect(
                role: role,
                interactive: interactive,
                prefersNativeGlass: prefersNativeGlass,
                nativeGlassStyle: nativeGlassStyle
            )
        )
        view.isUserInteractionEnabled = interactive
        view.contentView.isUserInteractionEnabled = interactive
        view.clipsToBounds = true
        return view
    }

    private static func applyToolbarGlassLayer(to view: UIVisualEffectView) {
        XabberGlassStyle.applySurface(
            to: view,
            role: .clearInputSurface,
            cornerStyle: .fixed(LiquidGlassMetrics.composerCornerRadius),
            interactive: true
        )
    }

    private static func removeChrome(from button: UIButton) {
        if button.configuration != nil {
            button.configuration = nil
        }
        if button.backgroundColor?.isEqual(UIColor.clear) != true {
            button.backgroundColor = .clear
        }
        if button.layer.borderWidth != 0 {
            button.layer.borderWidth = 0
        }
        if let borderColor = button.layer.borderColor,
           borderColor.alpha != 0 {
            button.layer.borderColor = UIColor.clear.cgColor
        }
    }

    private static func applyDetachedGlassButtonStyle(
        to button: UIButton,
        forceConfigurationUpdate: Bool = true
    ) {
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: button.tintColor,
            forceConfigurationUpdate: forceConfigurationUpdate
        )
    }

    private static func setDetachedGlassButtonChromeHidden(_ hidden: Bool, on button: UIButton) {
        NativeGlassBarStyle.setDetachedIconButtonChromeHidden(hidden, on: button)
    }

    private static func makeScheduledMessagesButtonImage() -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        return UIImage(systemName: "calendar.badge.clock", withConfiguration: configuration)
            ?? UIImage(systemName: "calendar", withConfiguration: configuration)
            ?? UIImage(systemName: "clock", withConfiguration: configuration)
    }

    private static let composerActionIconSize: CGFloat = 24

    final class ComposerContextPreviewView: UIView {
        enum Mode: Equatable {
            case forward
            case edit
        }

        weak var delegate: ChatViewMessagesPanelDelegate? = nil

        static let height: CGFloat = LiquidGlassMetrics.contextPreviewHeight

        private(set) var mode: Mode = .forward

        private let tapControl: UIControl = {
            let control = UIControl()
            control.backgroundColor = .clear
            control.translatesAutoresizingMaskIntoConstraints = false
            return control
        }()

        let accentView: UIView = {
            let view = UIView()
            view.backgroundColor = .tintColor
            view.layer.cornerRadius = 0.5
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }()

        let indicatorButton: UIButton = {
            AudioPlayerBarIconButtonStyle.makeButton()
        }()

        let titleLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .tintColor
            label.isUserInteractionEnabled = false
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

        let messageLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabel
            label.isUserInteractionEnabled = false
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }()

        let closeButton: UIButton = {
            let button = AudioPlayerBarIconButtonStyle.makeButton()
            AudioPlayerBarIconButtonStyle.setSystemIcon(
                named: "xmark",
                pointSize: AudioPlayerBarIconButtonStyle.compactXmarkPointSize,
                on: button
            )
            return button
        }()

        let labelsStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .fill
            stack.distribution = .fill
            stack.spacing = 1
            stack.isUserInteractionEnabled = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            return stack
        }()

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        func update(title: String, attributed text: NSAttributedString) {
            titleLabel.text = title
            messageLabel.attributedText = text
            messageLabel.lineBreakMode = .byTruncatingTail
            messageLabel.numberOfLines = 1
        }

        func update(title: String, normal text: String) {
            titleLabel.text = title
            messageLabel.text = text
            messageLabel.lineBreakMode = .byTruncatingTail
            messageLabel.numberOfLines = 1
        }

        func configure(mode: Mode) {
            self.mode = mode
            switch mode {
            case .forward:
                configureForForward()
            case .edit:
                configureForEdit()
            }
        }

        func configureForForward() {
            mode = .forward
            applyContextTint(.tintColor)
            AudioPlayerBarIconButtonStyle.setSystemIcon(named: "arrowshape.turn.up.left", on: indicatorButton)
        }

        func configureForEdit() {
            mode = .edit
            applyContextTint(.systemOrange)
            AudioPlayerBarIconButtonStyle.setTemplateIcon(
                imageLiteral("xabber.pencil.cap", dimension: 18),
                on: indicatorButton
            )
        }

        private func applyContextTint(_ color: UIColor) {
            accentView.backgroundColor = color
            titleLabel.textColor = color
        }

        private func setup() {
            backgroundColor = .clear
            translatesAutoresizingMaskIntoConstraints = false
            layer.shadowOpacity = 0

            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(messageLabel)

            addSubview(tapControl)
            addSubview(accentView)
            addSubview(indicatorButton)
            addSubview(labelsStack)
            addSubview(closeButton)

            tapControl.addTarget(self, action: #selector(onPreviewTouchUpInside), for: .touchUpInside)
            indicatorButton.addTarget(self, action: #selector(onPreviewTouchUpInside), for: .touchUpInside)
            closeButton.addTarget(self, action: #selector(onCloseButtonTouchUpInside), for: .touchUpInside)

            NSLayoutConstraint.activate([
                tapControl.leadingAnchor.constraint(equalTo: leadingAnchor),
                tapControl.trailingAnchor.constraint(equalTo: trailingAnchor),
                tapControl.topAnchor.constraint(equalTo: topAnchor),
                tapControl.bottomAnchor.constraint(equalTo: bottomAnchor),

                indicatorButton.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: AudioPlayerBarIconButtonStyle.contentInset
                ),
                indicatorButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                indicatorButton.widthAnchor.constraint(equalToConstant: AudioPlayerBarIconButtonStyle.buttonSize),
                indicatorButton.heightAnchor.constraint(equalToConstant: AudioPlayerBarIconButtonStyle.buttonSize),

                accentView.leadingAnchor.constraint(
                    equalTo: indicatorButton.trailingAnchor,
                    constant: AudioPlayerBarIconButtonStyle.adjacentSpacing
                ),
                accentView.centerYAnchor.constraint(equalTo: centerYAnchor),
                accentView.widthAnchor.constraint(equalToConstant: 1),
                accentView.heightAnchor.constraint(equalToConstant: 24),

                labelsStack.leadingAnchor.constraint(
                    equalTo: accentView.trailingAnchor,
                    constant: AudioPlayerBarIconButtonStyle.adjacentSpacing
                ),
                labelsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
                labelsStack.trailingAnchor.constraint(
                    equalTo: closeButton.leadingAnchor,
                    constant: -AudioPlayerBarIconButtonStyle.adjacentSpacing
                ),

                closeButton.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -AudioPlayerBarIconButtonStyle.contentInset
                ),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: AudioPlayerBarIconButtonStyle.buttonSize),
                closeButton.heightAnchor.constraint(equalToConstant: AudioPlayerBarIconButtonStyle.buttonSize)
            ])

            configureForForward()
        }

        func update() {
            setNeedsLayout()
        }

        @objc
        private func onCloseButtonTouchUpInside(_ sender: UIButton) {
            delegate?.messagesPanelOnClose()
        }

        @objc
        private func onPreviewTouchUpInside(_ sender: UIControl) {
            delegate?.messagesPanelOnIndicatorTouch()
        }
    }

    class SearchPanel: UIView {
        private struct ActiveCapsuleTransition {
            let token: Int
            let finalState: ChatSearchBottomActionBarLayout.LeadingState
            let animator: ChatSearchModeAnimating
        }
        
        enum State {
            case empty
            case withResults
        }

        enum RenderState: Equatable {
            case idle
            case loading
            case emptyResults
            case results(current: Int, total: Int, isLoadingContext: Bool)

            var legacyState: State {
                switch self {
                case .idle:
                    return .empty
                case .loading, .emptyResults, .results:
                    return .withResults
                }
            }

            var isServerLoading: Bool {
                switch self {
                case .loading:
                    return true
                case .idle, .emptyResults, .results:
                    return false
                }
            }

            var isLoadingContext: Bool {
                switch self {
                case .results(_, _, let isLoadingContext):
                    return isLoadingContext
                case .idle, .loading, .emptyResults:
                    return false
                }
            }
        }

        enum SurfaceMode: Equatable {
            case chat
            case list
        }

        static func productionAnimationSpecs(
            for preferences: ChatSearchAnimationSpec.AccessibilityPreferences
        ) -> (base: ChatSearchAnimationSpec, active: ChatSearchAnimationSpec) {
            let base = ChatSearchAnimationSpec.production
            return (base, base.resolved(for: preferences))
        }

        var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular {
            didSet {
                if self.conversationType == .omemo {
                    self.changeChatButton.setTitle("Search non-encrypted messages", for: .normal)
                } else {
                    self.changeChatButton.setTitle("Search encrypted messages", for: .normal)
                }
            }
        }
        
        var state: State = .empty
        private(set) var renderState: RenderState = .idle
        private var isApplyingRenderState = false
        private var lastCurrentResultIndex: Int = -1
        private var lastTotalResults: Int = 0
        private(set) var surfaceMode: SurfaceMode = .chat
        private var baseAnimationSpec: ChatSearchAnimationSpec
        private(set) var animationSpec: ChatSearchAnimationSpec
        private let capsuleAnimatorFactory: ChatSearchModeAnimatorFactory
        private var activeCapsuleTransition: ActiveCapsuleTransition?
        private var capsuleTransitionToken = 0
        private var desiredCounterText: String?
        private let localization: ChatSearchLocalization
        private let countFormatter: ChatSearchBottomCountFormatter
        private(set) var leadingLayoutState: ChatSearchBottomActionBarLayout.LeadingState = .calendarOnly
        private(set) var capsuleTransitionCount = 0
        private(set) var isCapsuleTransitioning = false
        private(set) var adaptiveEnvironment = ChatSearchAdaptiveEnvironment.standard
        private(set) var adaptiveSurfaceStyle = ChatSearchAdaptiveAppearance.surfaceStyle(
            for: .standard
        )
        var shouldShowSeekUpDownButtons: Bool = true
        fileprivate var acceptsComposerHitTesting = true
        
        open var onChangeConversationTypeCallback: ((ClientSynchronizationManager.ConversationType) -> Void)? = nil
        open var onSeekUpCallback: (() -> Void)? = nil
        open var onSeekDownCallback: (() -> Void)? = nil
        open var onChangeViewStateCallback: (() -> Void)? = nil
        open var onCancelCallback: (() -> Void)? = nil
        open var onCalendarCallback: (() -> Void)? = nil

        let leadingSurfaceView: UIVisualEffectView = {
            let view = UIVisualEffectView()
            NativeGlassBarStyle.applySurface(to: view, cornerStyle: .capsule, interactive: true)
            return view
        }()

        let trailingSurfaceView: UIVisualEffectView = {
            let view = UIVisualEffectView()
            NativeGlassBarStyle.applySurface(to: view, cornerStyle: .capsule, interactive: true)
            return view
        }()

        var surfaceView: UIVisualEffectView { leadingSurfaceView }

        let calendarButton: UIButton = {
            let button = ChatSearchExpandedHitButton(type: .system)
            button.setImage(imageLiteral("calendar", dimension: 19.5), for: .normal)
            button.tintColor = NativeGlassBarStyle.iconTintColor
            button.accessibilityIdentifier = ChatSearchAccessibilityIdentifier.calendarButton
            return button
        }()

        let cancelButton: UIButton = {
            let button = UIButton(type: .system)
            button.setImage(imageLiteral("xmark", dimension: NativeGlassBarStyle.iconSize), for: .normal)
            button.tintColor = NativeGlassBarStyle.iconTintColor
            button.accessibilityIdentifier = ChatSearchAccessibilityIdentifier.cancel
            button.accessibilityLabel = "Cancel".localizeString(id: "cancel", arguments: [])
            return button
        }()
        
        let viewModeButton: UIButton = {
            let button = UIButton(type: .system)
            button.tintColor = NativeGlassBarStyle.iconTintColor
            button.setTitleColor(NativeGlassBarStyle.iconTintColor, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.78
            button.accessibilityIdentifier = ChatSearchAccessibilityIdentifier.viewModeControl
            return button
        }()

        var listButton: UIButton { viewModeButton }
        
        let changeChatButton: UIButton = {
            let button = UIButton()
            
            button.setTitle("Search encrypted messages", for: .normal)
            button.tintColor = .tintColor
            button.setTitleColor(.tintColor, for: .normal)
            
            return button
        }()
        
        let activityIndicator: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .medium)
            
            view.isHidden = true
            view.hidesWhenStopped = false
            view.accessibilityIdentifier = ChatSearchAccessibilityIdentifier.loading
            
            return view
        }()
        
        let counterLabel: UILabel = {
            let label = UILabel()
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.85
            label.accessibilityIdentifier = ChatSearchAccessibilityIdentifier.resultsCount
            
            return label
        }()
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.spacing = 6
            
            return stack
        }()
        
        let spacerView: UIView = {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return view
        }()

        override init(frame: CGRect) {
            let localization = ChatSearchLocalization.production()
            let animationSpecs = Self.productionAnimationSpecs(
                for: .init(
                    reduceMotion: UIAccessibility.isReduceMotionEnabled,
                    reduceTransparency: UIAccessibility.isReduceTransparencyEnabled
                )
            )
            self.animationSpec = animationSpecs.active
            self.baseAnimationSpec = animationSpecs.base
            self.capsuleAnimatorFactory = UIKitChatSearchModeAnimatorFactory()
            self.localization = localization
            self.countFormatter = ChatSearchBottomCountFormatter(localization: localization)
            super.init(frame: frame)
            self.setup()
        }

        init(
            frame: CGRect,
            animationSpec: ChatSearchAnimationSpec,
            localization: ChatSearchLocalization = .production(),
            capsuleAnimatorFactory: ChatSearchModeAnimatorFactory = UIKitChatSearchModeAnimatorFactory()
        ) {
            self.animationSpec = animationSpec
            self.baseAnimationSpec = animationSpec
            self.capsuleAnimatorFactory = capsuleAnimatorFactory
            self.localization = localization
            self.countFormatter = ChatSearchBottomCountFormatter(localization: localization)
            super.init(frame: frame)
            self.setup()
        }
        
        required init?(coder: NSCoder) {
            let localization = ChatSearchLocalization.production()
            let animationSpecs = Self.productionAnimationSpecs(
                for: .init(
                    reduceMotion: UIAccessibility.isReduceMotionEnabled,
                    reduceTransparency: UIAccessibility.isReduceTransparencyEnabled
                )
            )
            self.animationSpec = animationSpecs.active
            self.baseAnimationSpec = animationSpecs.base
            self.capsuleAnimatorFactory = UIKitChatSearchModeAnimatorFactory()
            self.localization = localization
            self.countFormatter = ChatSearchBottomCountFormatter(localization: localization)
            super.init(coder: coder)
            self.setup()
        }

        deinit {
            activeCapsuleTransition?.animator.stopAnimation(true)
            NotificationCenter.default.removeObserver(self)
        }

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: ChatSearchBottomActionBarLayout.height)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let frames = ChatSearchBottomActionBarLayout.frames(
                in: bounds,
                safeAreaInsets: safeAreaInsets,
                layoutDirection: adaptiveEnvironment.layoutDirection,
                leadingState: leadingLayoutState
            )
            leadingSurfaceView.frame = frames.leadingCapsule
            trailingSurfaceView.frame = frames.trailingCapsule
            leadingSurfaceView.layer.cornerRadius = ChatSearchBottomActionBarLayout.height / 2
            trailingSurfaceView.layer.cornerRadius = ChatSearchBottomActionBarLayout.height / 2
            leadingSurfaceView.contentView.layoutIfNeeded()
            trailingSurfaceView.contentView.layoutIfNeeded()
            [calendarButton, viewModeButton].forEach {
                $0.updateChatSearchAccessibilityFrame()
            }
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard acceptsComposerHitTesting,
                  !isHidden,
                  isUserInteractionEnabled,
                  alpha > 0.01 else {
                return false
            }
            return super.point(inside: point, with: event) ||
                expandedCalendarHitView(for: point, with: event) != nil
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard acceptsComposerHitTesting,
                  !isHidden,
                  isUserInteractionEnabled,
                  alpha > 0.01 else {
                return nil
            }
            if let calendarHit = expandedCalendarHitView(for: point, with: event) {
                return calendarHit
            }
            return super.hitTest(point, with: event)
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory ||
                    previousTraitCollection?.accessibilityContrast != traitCollection.accessibilityContrast ||
                    previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle ||
                    previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else {
                return
            }
            applyAdaptiveEnvironment(.current(for: self))
        }
        
        func activateConstraints() {
            let counterTrailingConstraint = self.counterLabel.trailingAnchor.constraint(
                equalTo: self.leadingSurfaceView.contentView.trailingAnchor,
                constant: -10
            )
            counterTrailingConstraint.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                self.calendarButton.leadingAnchor.constraint(
                    equalTo: self.leadingSurfaceView.contentView.leadingAnchor
                ),
                self.calendarButton.topAnchor.constraint(
                    equalTo: self.leadingSurfaceView.contentView.topAnchor
                ),
                self.calendarButton.bottomAnchor.constraint(
                    equalTo: self.leadingSurfaceView.contentView.bottomAnchor
                ),
                self.calendarButton.widthAnchor.constraint(
                    equalToConstant: ChatSearchBottomActionBarLayout.minimumControlWidth
                ),
                self.counterLabel.leadingAnchor.constraint(
                    equalTo: self.calendarButton.trailingAnchor,
                    constant: 2
                ),
                counterTrailingConstraint,
                self.counterLabel.topAnchor.constraint(
                    equalTo: self.leadingSurfaceView.contentView.topAnchor
                ),
                self.counterLabel.bottomAnchor.constraint(
                    equalTo: self.leadingSurfaceView.contentView.bottomAnchor
                ),
                self.viewModeButton.leadingAnchor.constraint(
                    equalTo: self.trailingSurfaceView.contentView.leadingAnchor
                ),
                self.viewModeButton.trailingAnchor.constraint(
                    equalTo: self.trailingSurfaceView.contentView.trailingAnchor
                ),
                self.viewModeButton.topAnchor.constraint(
                    equalTo: self.trailingSurfaceView.contentView.topAnchor
                ),
                self.viewModeButton.bottomAnchor.constraint(
                    equalTo: self.trailingSurfaceView.contentView.bottomAnchor
                )
            ])
        }
        
        open var isInLoadingState: Bool = false {
            didSet {
                guard !self.isApplyingRenderState else { return }
                if self.isInLoadingState {
                    self.applyRenderState(.loading)
                } else {
                    self.changeState(to: self.state)
                }
            }
        }
        
        open func changeState(to newState: State) {
            switch newState {
            case .empty:
                self.applyRenderState(.idle)
            case .withResults:
                if self.isInLoadingState {
                    self.applyRenderState(.loading)
                } else if self.lastTotalResults == 0 {
                    self.applyRenderState(.emptyResults)
                } else {
                    self.applyRenderState(
                        .results(
                            current: self.lastCurrentResultIndex,
                            total: self.lastTotalResults,
                            isLoadingContext: self.renderState.isLoadingContext
                        )
                    )
                }
            }
        }
        
        open func updateResults(current: Int, total: Int) {
            self.lastCurrentResultIndex = current
            self.lastTotalResults = total
            if total == 0 {
                self.applyRenderState(.emptyResults)
            } else {
                self.applyRenderState(
                    .results(
                        current: current,
                        total: total,
                        isLoadingContext: self.renderState.isLoadingContext
                    )
                )
            }
        }

        open func applyRenderState(_ newState: RenderState) {
            applyRenderState(newState, surfaceMode: surfaceMode, animated: true)
        }

        func applyRenderState(
            _ newState: RenderState,
            surfaceMode newSurfaceMode: SurfaceMode,
            animated: Bool
        ) {
            self.renderState = newState
            self.state = newState.legacyState
            self.surfaceMode = newSurfaceMode
            self.setLegacyLoadingFlag(newState.isServerLoading)

            let current: Int
            let total: Int
            switch newState {
            case .idle, .loading, .emptyResults:
                current = -1
                total = 0
                self.lastCurrentResultIndex = -1
                self.lastTotalResults = 0
            case .results(let resultIndex, let resultCount, _):
                current = resultIndex
                total = max(0, resultCount)
                self.lastCurrentResultIndex = current
                self.lastTotalResults = total
            }

            let hasCommittedCurrentResult = current >= 0 && current < total
            let hasResults = total > 0
            let counterText: String?
            if hasResults {
                if newSurfaceMode == .chat && hasCommittedCurrentResult {
                    counterText = countFormatter.current(current, total: total)
                } else {
                    counterText = countFormatter.messages(total: total)
                }
            } else {
                counterText = nil
            }
            desiredCounterText = counterText
            counterLabel.layer.removeAnimation(forKey: "chat-search-counter")
            counterLabel.accessibilityValue = counterText
            counterLabel.accessibilityElementsHidden = !hasResults
            counterLabel.isAccessibilityElement = hasResults

            let viewModeTitle: String
            switch newSurfaceMode {
            case .chat:
                viewModeTitle = localization.text(.showAsList)
            case .list:
                viewModeTitle = localization.text(.showAsChat)
            }
            viewModeButton.setTitle(viewModeTitle, for: .normal)
            viewModeButton.accessibilityLabel = viewModeTitle
            trailingSurfaceView.isHidden = !hasCommittedCurrentResult
            trailingSurfaceView.accessibilityElementsHidden = !hasCommittedCurrentResult
            viewModeButton.isHidden = !hasCommittedCurrentResult
            viewModeButton.isEnabled = hasCommittedCurrentResult
            viewModeButton.accessibilityElementsHidden = !hasCommittedCurrentResult
            calendarButton.isHidden = false
            calendarButton.isEnabled = true

            cancelButton.isHidden = true
            stopLoadingIndicator()
            updateAccessibilityOrder(
                showsCounter: hasResults,
                hasCommittedCurrentResult: hasCommittedCurrentResult
            )
            transitionLeadingCapsule(
                to: hasResults ? .results : .calendarOnly,
                counterText: counterText,
                animated: animated
            )
        }

        func setSurfaceMode(_ newSurfaceMode: SurfaceMode, animated: Bool) {
            guard surfaceMode != newSurfaceMode else { return }
            applyRenderState(renderState, surfaceMode: newSurfaceMode, animated: animated)
        }

        func updateAnimationSpec(_ animationSpec: ChatSearchAnimationSpec) {
            settleCapsuleTransitionIfNeeded()
            self.baseAnimationSpec = animationSpec
            self.animationSpec = animationSpec
        }

        func applyAdaptiveEnvironment(_ environment: ChatSearchAdaptiveEnvironment) {
            adaptiveEnvironment = environment
            semanticContentAttribute = environment.layoutDirection == .rightToLeft
                ? .forceRightToLeft
                : .forceLeftToRight
            leadingSurfaceView.semanticContentAttribute = semanticContentAttribute
            trailingSurfaceView.semanticContentAttribute = semanticContentAttribute
            animationSpec = baseAnimationSpec.resolved(
                for: environment.animationPreferences
            )
            settleCapsuleTransitionIfNeeded()
            counterLabel.font = ChatSearchAdaptiveLayoutPolicy.scaledFont(
                baseSize: 14,
                weight: .regular,
                textStyle: .subheadline,
                contentSizeCategory: environment.contentSizeCategory,
                maximumPointSize: 22
            )
            viewModeButton.titleLabel?.font = ChatSearchAdaptiveLayoutPolicy.scaledFont(
                baseSize: 14,
                weight: .semibold,
                textStyle: .subheadline,
                contentSizeCategory: environment.contentSizeCategory,
                maximumPointSize: 22
            )
            adaptiveSurfaceStyle = ChatSearchAdaptiveAppearance.applySurface(
                to: leadingSurfaceView,
                role: .bar,
                cornerStyle: .capsule,
                interactive: true,
                prefersNativeGlass: true,
                environment: environment
            )
            _ = ChatSearchAdaptiveAppearance.applySurface(
                to: trailingSurfaceView,
                role: .bar,
                cornerStyle: .capsule,
                interactive: true,
                prefersNativeGlass: true,
                environment: environment
            )
            setNeedsLayout()
        }

        private func setLegacyLoadingFlag(_ loading: Bool) {
            guard self.isInLoadingState != loading else { return }
            self.isApplyingRenderState = true
            self.isInLoadingState = loading
            self.isApplyingRenderState = false
        }

        private func startLoadingIndicator() {
            self.activityIndicator.isHidden = false
            self.activityIndicator.startAnimating()
        }

        private func stopLoadingIndicator() {
            self.activityIndicator.stopAnimating()
            self.activityIndicator.isHidden = true
        }

        private func updateAccessibilityOrder(
            showsCounter: Bool,
            hasCommittedCurrentResult: Bool
        ) {
            var elements: [Any] = [calendarButton]
            if showsCounter {
                elements.append(counterLabel)
            }
            if hasCommittedCurrentResult {
                elements.append(viewModeButton)
            }
            accessibilityElements = elements
        }

        private func transitionLeadingCapsule(
            to finalState: ChatSearchBottomActionBarLayout.LeadingState,
            counterText: String?,
            animated: Bool
        ) {
            let stateChanged = leadingLayoutState != finalState
            guard stateChanged else {
                if activeCapsuleTransition != nil {
                    if animated {
                        if finalState == .results {
                            counterLabel.text = counterText
                            counterLabel.isHidden = false
                        }
                        return
                    }
                    interruptActiveCapsuleTransition(preservingPresentationState: false)
                }
                applyFinalCapsuleState(finalState, counterText: counterText)
                return
            }

            layoutIfNeeded()
            let interruptedTransition = activeCapsuleTransition != nil
            interruptActiveCapsuleTransition(preservingPresentationState: true)
            leadingLayoutState = finalState
            capsuleTransitionToken &+= 1
            let token = capsuleTransitionToken
            let transition = animationSpec.bottomCapsule
            let shouldAnimateGeometry = animated && window != nil && transition.geometry.duration > 0
            let shouldAnimateText = animated && window != nil && transition.textAlpha.duration > 0

            guard shouldAnimateGeometry || shouldAnimateText else {
                applyFinalCapsuleState(finalState, counterText: counterText)
                return
            }

            if finalState == .results {
                counterLabel.text = counterText
                counterLabel.isHidden = false
                if !interruptedTransition {
                    counterLabel.alpha = 0
                }
            } else {
                counterLabel.isHidden = false
            }

            setNeedsLayout()
            if !shouldAnimateGeometry {
                layoutIfNeeded()
            }

            let targetAlpha: CGFloat = finalState == .results ? 1 : 0
            if !shouldAnimateText {
                counterLabel.alpha = targetAlpha
            }
            let timing = shouldAnimateGeometry ? transition.geometry : transition.textAlpha
            let animator = capsuleAnimatorFactory.makeAnimator(timing: timing) { [weak self] in
                guard let self else { return }
                if shouldAnimateGeometry {
                    self.layoutIfNeeded()
                }
                if shouldAnimateText {
                    self.counterLabel.alpha = targetAlpha
                }
            }
            let activeTransition = ActiveCapsuleTransition(
                token: token,
                finalState: finalState,
                animator: animator
            )
            activeCapsuleTransition = activeTransition
            isCapsuleTransitioning = true
            capsuleTransitionCount += 1
            animator.addCompletion { [weak self] _ in
                guard let self,
                      self.activeCapsuleTransition?.token == token else {
                    return
                }
                self.activeCapsuleTransition = nil
                self.isCapsuleTransitioning = false
                self.applyFinalCapsuleState(finalState, counterText: self.desiredCounterText)
            }
            animator.startAnimation()
        }

        private func interruptActiveCapsuleTransition(
            preservingPresentationState: Bool
        ) {
            guard let activeCapsuleTransition else { return }
            let presentedFrame = preservingPresentationState
                ? leadingSurfaceView.layer.presentation()?.frame
                : nil
            let presentedAlpha = preservingPresentationState
                ? counterLabel.layer.presentation()?.opacity
                : nil

            capsuleTransitionToken &+= 1
            activeCapsuleTransition.animator.stopAnimation(true)
            self.activeCapsuleTransition = nil
            isCapsuleTransitioning = false
            leadingSurfaceView.layer.removeAllAnimations()
            counterLabel.layer.removeAllAnimations()

            if let presentedFrame {
                leadingSurfaceView.frame = presentedFrame
            }
            if let presentedAlpha {
                counterLabel.alpha = CGFloat(presentedAlpha)
            }
        }

        private func applyFinalCapsuleState(
            _ finalState: ChatSearchBottomActionBarLayout.LeadingState,
            counterText: String?
        ) {
            leadingSurfaceView.layer.removeAllAnimations()
            counterLabel.layer.removeAllAnimations()
            setNeedsLayout()
            layoutIfNeeded()

            switch finalState {
            case .calendarOnly:
                counterLabel.text = nil
                counterLabel.alpha = 0
                counterLabel.isHidden = true
            case .results:
                counterLabel.text = counterText
                counterLabel.alpha = 1
                counterLabel.isHidden = false
            }
        }

        private func settleCapsuleTransitionIfNeeded() {
            guard activeCapsuleTransition != nil else { return }
            interruptActiveCapsuleTransition(preservingPresentationState: false)
            applyFinalCapsuleState(leadingLayoutState, counterText: desiredCounterText)
        }

        fileprivate func expandedCalendarHitView(
            for point: CGPoint,
            with event: UIEvent?
        ) -> UIView? {
            guard !calendarButton.isHidden,
                  calendarButton.isEnabled,
                  calendarButton.alpha > 0.01 else {
                return nil
            }
            let buttonPoint = calendarButton.convert(point, from: self)
            return calendarButton.point(inside: buttonPoint, with: event)
                ? calendarButton
                : nil
        }

        @objc
        private func accessibilityAnimationPreferencesDidChange() {
            applyAdaptiveEnvironment(.current(for: self))
        }
        
        @objc
        private func onChangeConversationTypeButtonTouchUp(_ sender: UIButton) {
            self.onChangeConversationTypeCallback?(self.conversationType)
        }

        @objc
        private func onCancelButtonTouchUp(_ sender: UIButton) {
            self.onCancelCallback?()
        }
        
        @objc
        private func onChangeViewStateTouchUp(_ sender: UIButton) {
            self.onChangeViewStateCallback?()
        }

        @objc
        private func onCalendarTouchUp(_ sender: UIButton) {
            self.onCalendarCallback?()
        }
        
        func setup() {
            self.accessibilityIdentifier = ChatSearchAccessibilityIdentifier.resultsPanel
            self.isAccessibilityElement = false
            self.calendarButton.accessibilityLabel = localization.text(.calendar)
            self.counterLabel.isAccessibilityElement = true
            self.counterLabel.accessibilityLabel = localization.text(.resultsCountAccessibility)
            self.backgroundColor = .clear
            self.isOpaque = false
            self.leadingSurfaceView.autoresizingMask = []
            self.trailingSurfaceView.autoresizingMask = []
            self.calendarButton.translatesAutoresizingMaskIntoConstraints = false
            self.viewModeButton.translatesAutoresizingMaskIntoConstraints = false
            self.counterLabel.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(self.leadingSurfaceView)
            self.addSubview(self.trailingSurfaceView)
            self.leadingSurfaceView.contentView.addSubview(self.calendarButton)
            self.leadingSurfaceView.contentView.addSubview(self.counterLabel)
            self.trailingSurfaceView.contentView.addSubview(self.viewModeButton)
            self.activateConstraints()
            NativeGlassBarStyle.applyIconButtonStyle(
                to: self.calendarButton,
                tintColor: NativeGlassBarStyle.iconTintColor,
                prefersNativeGlass: false
            )
            self.changeChatButton.addTarget(self, action: #selector(onChangeConversationTypeButtonTouchUp), for: .touchUpInside)
            self.calendarButton.addTarget(self, action: #selector(onCalendarTouchUp), for: .touchUpInside)
            self.viewModeButton.addTarget(self, action: #selector(onChangeViewStateTouchUp), for: .touchUpInside)
            self.cancelButton.isHidden = true
            self.activityIndicator.isHidden = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(accessibilityAnimationPreferencesDidChange),
                name: UIAccessibility.reduceMotionStatusDidChangeNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(accessibilityAnimationPreferencesDidChange),
                name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                object: nil
            )
            self.applyAdaptiveEnvironment(.current(for: self))
            self.applyRenderState(.idle, surfaceMode: .chat, animated: false)
        }
    }

    final class MentionSuggestionsPanel: UIView, UITableViewDataSource, UITableViewDelegate {

        final class SuggestionCell: UITableViewCell {

            static let reuseIdentifier = "MentionSuggestionCell"

            private let avatarView: AvatarView = {
                let view = AvatarView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
                view.backgroundColor = .systemGray5
                return view
            }()

            private let nicknameLabel: UILabel = {
                let label = UILabel()
                label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
                label.textColor = .label
                return label
            }()

            private let secondaryLabel: UILabel = {
                let label = UILabel()
                label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
                label.textColor = .secondaryLabel
                return label
            }()

            private let labelsStack: UIStackView = {
                let stack = UIStackView()
                stack.axis = .vertical
                stack.spacing = 2
                stack.alignment = .fill
                return stack
            }()

            override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
                super.init(style: style, reuseIdentifier: reuseIdentifier)
                selectionStyle = .default
                backgroundColor = .clear
                contentView.backgroundColor = .clear
                labelsStack.addArrangedSubview(nicknameLabel)
                labelsStack.addArrangedSubview(secondaryLabel)
                avatarView.translatesAutoresizingMaskIntoConstraints = false
                labelsStack.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(avatarView)
                contentView.addSubview(labelsStack)
                NSLayoutConstraint.activate([
                    avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
                    avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                    avatarView.widthAnchor.constraint(equalToConstant: 32),
                    avatarView.heightAnchor.constraint(equalToConstant: 32),
                    labelsStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
                    labelsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
                    labelsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                    labelsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
                ])
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func configure(with item: ComposerMentionCandidate) {
                nicknameLabel.text = item.nickname
                secondaryLabel.text = item.secondaryText
                avatarView.initials = item.avatarInitials
            }
        }

        private enum State {
            case empty
            case loading
            case results
        }

        private let blurView: UIVisualEffectView = {
            let effect = UIBlurEffect(style: .systemMaterial)
            let view = UIVisualEffectView(effect: effect)
            view.clipsToBounds = true
            view.layer.cornerRadius = 18
            view.layer.cornerCurve = .continuous
            return view
        }()

        private let tableView: UITableView = {
            let tableView = UITableView(frame: .zero, style: .plain)
            tableView.separatorStyle = .none
            tableView.backgroundColor = .clear
            tableView.showsVerticalScrollIndicator = false
            tableView.keyboardDismissMode = .none
            return tableView
        }()

        private let emptyLabel: UILabel = {
            let label = UILabel()
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            label.text = "No users found"
            label.isHidden = true
            return label
        }()

        private let activityIndicator: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .medium)
            view.hidesWhenStopped = true
            return view
        }()

        private var state: State = .empty
        private(set) var items: [ComposerMentionCandidate] = []
        private(set) var highlightedIndex: Int = 0
        var onSelect: ((ComposerMentionCandidate) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        private func setup() {
            isHidden = true
            clipsToBounds = false
            backgroundColor = .clear
            layer.shadowColor = UIColor.black.withAlphaComponent(0.22).cgColor
            layer.shadowOpacity = 1
            layer.shadowRadius = 18
            layer.shadowOffset = CGSize(width: 0, height: 8)

            addSubview(blurView)
            blurView.contentView.addSubview(tableView)
            blurView.contentView.addSubview(emptyLabel)
            blurView.contentView.addSubview(activityIndicator)

            blurView.translatesAutoresizingMaskIntoConstraints = false
            tableView.translatesAutoresizingMaskIntoConstraints = false
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            activityIndicator.translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
                blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
                blurView.topAnchor.constraint(equalTo: topAnchor),
                blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
                tableView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
                tableView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
                tableView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 6),
                tableView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -6),
                emptyLabel.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
                activityIndicator.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
                activityIndicator.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor)
            ])

            tableView.dataSource = self
            tableView.delegate = self
            tableView.rowHeight = 52
            tableView.register(SuggestionCell.self, forCellReuseIdentifier: SuggestionCell.reuseIdentifier)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 18).cgPath
        }

        func update(items: [ComposerMentionCandidate], isLoading: Bool) {
            self.items = items
            if isLoading {
                state = .loading
            } else if items.isEmpty {
                state = .empty
            } else {
                state = .results
            }
            highlightedIndex = min(highlightedIndex, max(items.count - 1, 0))
            applyState()
        }

        func preferredHeight(maxHeight: CGFloat) -> CGFloat {
            switch state {
            case .loading, .empty:
                return 84
            case .results:
                let contentHeight = CGFloat(items.count) * tableView.rowHeight + 12
                return min(max(contentHeight, 52), maxHeight)
            }
        }

        func moveSelection(offset: Int) {
            guard !items.isEmpty else { return }
            highlightedIndex = max(0, min(items.count - 1, highlightedIndex + offset))
            refreshSelection(animated: true)
        }

        @discardableResult
        func selectHighlightedItem() -> ComposerMentionCandidate? {
            guard !items.isEmpty, highlightedIndex < items.count else { return nil }
            let item = items[highlightedIndex]
            onSelect?(item)
            return item
        }

        private func applyState() {
            switch state {
            case .loading:
                isHidden = false
                tableView.isHidden = true
                emptyLabel.isHidden = true
                activityIndicator.startAnimating()
            case .empty:
                isHidden = false
                tableView.isHidden = true
                emptyLabel.isHidden = false
                activityIndicator.stopAnimating()
            case .results:
                isHidden = false
                tableView.isHidden = false
                emptyLabel.isHidden = true
                activityIndicator.stopAnimating()
                tableView.reloadData()
                refreshSelection(animated: false)
            }
        }

        private func refreshSelection(animated: Bool) {
            guard !items.isEmpty else { return }
            let indexPath = IndexPath(row: highlightedIndex, section: 0)
            tableView.selectRow(at: indexPath, animated: animated, scrollPosition: .none)
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            items.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SuggestionCell.reuseIdentifier, for: indexPath) as? SuggestionCell else {
                return UITableViewCell()
            }
            cell.configure(with: items[indexPath.row])
            return cell
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            highlightedIndex = indexPath.row
            onSelect?(items[indexPath.row])
        }
    }
    
    class SelectionPanel: UIView {
        enum Metrics {
            static let height: CGFloat = NativeGlassBarStyle.minimumHeight
            static let contentInset: CGFloat = NativeGlassBarStyle.contentInset
            static let buttonSize: CGFloat = NativeGlassBarStyle.buttonSize
            static let iconSize: CGFloat = NativeGlassBarStyle.iconSize
        }

        weak var delegate: MessagesSelectionPanelActionDelegate? = nil

        let surfaceView: UIVisualEffectView = {
            let view = UIVisualEffectView(effect: NativeGlassBarStyle.makeEffect(interactive: true))

            view.translatesAutoresizingMaskIntoConstraints = false
            NativeGlassBarStyle.applySurface(to: view, cornerStyle: .capsule, interactive: true)

            return view
        }()

        let deleteButton: UIButton = {
            SelectionPanel.makeButton(imageName: "trash", accessibilityLabel: "Delete")
        }()

        let shareButton: UIButton = {
            SelectionPanel.makeButton(imageName: "square.and.arrow.up", accessibilityLabel: "Share")
        }()

        let replyButton: UIButton = {
            SelectionPanel.makeButton(imageName: "arrowshape.turn.up.left", accessibilityLabel: "Reply")
        }()

        let copyButton: UIButton = {
            SelectionPanel.makeButton(imageName: "doc.on.doc", accessibilityLabel: "Copy")
        }()

        let forwardButton: UIButton = {
            SelectionPanel.makeButton(imageName: "arrowshape.turn.up.right", accessibilityLabel: "Forward")
        }()

        let stack:UIStackView = {
            let stack = UIStackView()

            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .equalSpacing
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false

            return stack
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        internal var buttonConstraints: [NSLayoutConstraint] = []

        internal func setup() {
            self.backgroundColor = .clear
            self.isOpaque = false
            self.addSubview(self.surfaceView)
            self.surfaceView.contentView.addSubview(self.stack)
            self.stack.addArrangedSubview(self.deleteButton)
            self.stack.addArrangedSubview(self.shareButton)
            self.stack.addArrangedSubview(self.copyButton)
            self.stack.addArrangedSubview(self.replyButton)
            self.stack.addArrangedSubview(self.forwardButton)
            self.deleteButton.addTarget(self, action: #selector(onDeleteButtonPress), for: .touchUpInside)
            self.shareButton.addTarget(self, action: #selector(onShareButtonPress), for: .touchUpInside)
            self.copyButton.addTarget(self, action: #selector(onCopyButtonPress), for: .touchUpInside)
            self.replyButton.addTarget(self, action: #selector(onReplyButtonPress), for: .touchUpInside)
            self.forwardButton.addTarget(self, action: #selector(onForwardButtonPress), for: .touchUpInside)

            let buttons = [self.deleteButton, self.shareButton, self.copyButton, self.replyButton, self.forwardButton]
            let constraints = buttons.compactMap({ return [
                $0.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
                $0.heightAnchor.constraint(equalToConstant: Metrics.buttonSize)
            ] }).flatMap({ $0 }) + [
                self.surfaceView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                self.surfaceView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
                self.surfaceView.topAnchor.constraint(equalTo: self.topAnchor),
                self.surfaceView.bottomAnchor.constraint(equalTo: self.bottomAnchor),

                self.stack.leadingAnchor.constraint(
                    equalTo: self.surfaceView.contentView.leadingAnchor,
                    constant: Metrics.contentInset
                ),
                self.stack.trailingAnchor.constraint(
                    equalTo: self.surfaceView.contentView.trailingAnchor,
                    constant: -Metrics.contentInset
                ),
                self.stack.topAnchor.constraint(equalTo: self.surfaceView.contentView.topAnchor),
                self.stack.bottomAnchor.constraint(equalTo: self.surfaceView.contentView.bottomAnchor)
            ]
            NSLayoutConstraint.activate(constraints)
        }

        final func update() {
            NativeGlassBarStyle.applySurface(to: surfaceView, cornerStyle: .capsule, interactive: true)
            [deleteButton, shareButton, copyButton, replyButton, forwardButton].forEach {
                NativeGlassBarStyle.applyIconButtonStyle(
                    to: $0,
                    tintColor: NativeGlassBarStyle.iconTintColor,
                    prefersNativeGlass: false,
                    forceConfigurationUpdate: false
                )
            }
        }

        private static func makeButton(
            imageName: String,
            accessibilityLabel: String
        ) -> UIButton {
            let button = UIButton(type: .system)
            let image = imageLiteral(imageName, dimension: Metrics.iconSize)?
                .withRenderingMode(.alwaysTemplate)

            button.accessibilityLabel = accessibilityLabel
            NativeGlassBarStyle.applyIconButtonStyle(
                to: button,
                tintColor: NativeGlassBarStyle.iconTintColor,
                image: image,
                prefersNativeGlass: false
            )

            return button
        }
        
        @objc
        internal func onCloseButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onClose: self)
        }
        
        @objc
        internal func onDeleteButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onDelete: self)
        }
        
        @objc
        internal func onCopyButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onCopy: self)
        }
        
        @objc
        internal func onShareButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onShare: self)
        }
        
        @objc
        internal func onReplyButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onReply: self)
        }
        
        @objc
        internal func onForwardButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onForward: self)
        }
        
        @objc
        internal func onEditButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onEdit: self)
        }
        
        open func show() {
            NSLayoutConstraint.activate(buttonConstraints)
        }
        
        open func hide() {
            NSLayoutConstraint.deactivate(buttonConstraints)
        }
        
        open func updateSelectionCount(_ count: Int) {
            
        }
        
    }

    class RecordAndPlayPanel: UIView {
        let recordIndicatorSize: CGFloat = 8
        
        let deleteButton: UIButton = {
            let button = UIButton(frame: CGRect(width: 44, height: 38))
            
            button.tintColor = .tintColor
            button.setImage(imageLiteral("trash"), for: .normal)
            button.tintColor = .systemRed
            
            return button
        }()
        
        let playButton: UIButton = {
            let button = UIButton(frame: CGRect(width: 38, height: 38))
            
            button.tintColor = .systemBackground
            button.setImage(imageLiteral("play.fill"), for: .normal)
            
            return button
        }()
        
        let backghroundWaveform: UIView = {
            let view = UIView(frame: .zero)
            
            view.layer.cornerRadius = 19
            
            return view
        }()
        
        let waveform: AudioVisualizationView = {
            let view = AudioVisualizationView()
            
            view.audioVisualizationMode = .read
            view.audioVisualizationType = .both
            view.backgroundColor = .clear
            view.currentGradientPercentage = 0.0
            view.gradientStartColor = UIColor.systemBackground
            view.gradientEndColor = UIColor.systemBackground
            view.barBackgroundFillColor = UIColor.systemBackground.withAlphaComponent(0.34)
            view.meteringLevelBarWidth = 2
            view.meteringLevelBarCornerRadius = 2
            view.meteringLevelBarInterItem = 1.5
            view.progressBarLineHeight = 0.5
            view.progressBarMiddleOffset = 0
            view.audioVisualizationTimeInterval = 0.025
            
            return view
        }()
        
        
        
        let timeLabel: UILabel = {
            let label = UILabel(frame: CGRect(width: 72, height: 20))
            
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = .systemBackground
            label.text = ""
            
            return label
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        
        internal weak var delegate: XabberInputBarDelegate? = nil
        internal var onDelete: (() -> Void)? = nil
        internal var onPlay: (() -> Void)? = nil
        
        internal func setup() {
            self.backgroundColor = .clear
            self.addSubview(deleteButton)
            self.addSubview(backghroundWaveform)
            self.backghroundWaveform.addSubview(playButton)
            self.backghroundWaveform.addSubview(waveform)
            self.backghroundWaveform.addSubview(timeLabel)
            self.deleteButton.addTarget(self, action: #selector(self.onDeleteButtonTouchUpInside), for: .touchUpInside)
            self.playButton.addTarget(self, action: #selector(self.onPlayButtonTouchUpInside), for: .touchUpInside)
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(self.onPanGestureAppear))
            self.waveform.addGestureRecognizer(gesture)
            self.waveform.drawCallback = { [weak self] in
                self?.updateTimeLabel()
            }
        }
        
        public final func updateTimeLabel() {
            if AudioManager.shared.player != nil {
                if let currentDuration = AudioManager.shared.player?.currentTime {
                    self.timeLabel.text = currentDuration.minuteFormatedString
                } else {
                    self.timeLabel.text = self.duration.minuteFormatedString
                }
            } else {
                self.timeLabel.text = self.duration.minuteFormatedString
            }
        }
        
        @objc
        private func onPanGestureAppear(_ sender: UIPanGestureRecognizer) {
            let point = sender.translation(in: self)
            let fullWidth: CGFloat = self.waveform.frame.width
            let currentPosition: CGFloat = [[point.x, 1.0].max() ?? 1.0, fullWidth].min() ?? 1.0
            let percentage = Float(currentPosition / fullWidth)
            switch sender.state {
                case .changed:
                    self.waveform.pause()
                    self.waveform.setProgress(percentage)
                case .ended:
                    self.waveform.stop()
                    self.waveform.setProgress(percentage)
                    guard let newDuration = self.delegate?.didSetAudioPositionBar(percentage: percentage) else {
                        return
                    }
                    self.waveform.startFrom = newDuration
                    self.waveform.play(for: self.duration - newDuration)
                case .cancelled, .failed:
                    guard let currentDuration = AudioManager.shared.player?.currentTime else {
                        return
                    }
                    let percentage: Float = Float(currentDuration / duration)
                    self.waveform.setProgress(percentage)
                    self.waveform.play(for: self.duration - currentDuration)
                default:
                    break
            }
        }
        
        var palette: MDCPalette = .amber
        
        final func update() {
            self.backghroundWaveform.backgroundColor = palette.tint500.withAlphaComponent(0.82)
            self.backghroundWaveform.layer.borderWidth = 0
            self.backghroundWaveform.layer.borderColor = nil
            self.backghroundWaveform.layer.cornerCurve = .continuous
            self.deleteButton.frame = CGRect(
                origin: CGPoint(x: 0, y: 0),
                size: CGSize(width: 44, height: 38)
            )
            self.deleteButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.10)
            self.deleteButton.layer.cornerRadius = 19
            self.deleteButton.layer.cornerCurve = .continuous
            self.backghroundWaveform.frame = CGRect(
                origin: CGPoint(x: 52, y: 0),
                size: CGSize(width: self.frame.width - 60, height: 38)
            )
            self.playButton.frame = CGRect(
                origin: CGPoint(x: 0, y: 0),
                size: CGSize(width: 38, height: 38)
            )
            self.waveform.frame = CGRect(
                origin: CGPoint(x: 38, y: 6),
                size: CGSize(width: self.backghroundWaveform.frame.width - 86, height: 26)
            )
            self.timeLabel.frame = CGRect(
                origin: CGPoint(x: self.backghroundWaveform.frame.width - 44, y: 4),
                size: CGSize(width: 44, height: 30)
            )
        }
        
        var startDate: Date? = nil
        var duration: TimeInterval = 0
        
        func configure(pcm: [Float], duration: TimeInterval) {
            if pcm.isEmpty {
                waveform.meteringLevels = (0..<52).compactMap { _ in return 0.1 }
            } else {
                waveform.meteringLevels = pcm.compactMap { return $0 < 0.1 ? 0.1 : $0 }
            }
            self.timeLabel.text = duration.minuteFormatedString
            self.duration = duration
            
        }
        
        @objc
        internal func onDeleteButtonTouchUpInside(_ sender: UIButton) {
            self.onDelete?()
        }
        
        @objc
        internal func onPlayButtonTouchUpInside(_ sender: UIButton) {
            self.onPlay?()
        }
        
        func play(for duration: TimeInterval) {
            self.duration = duration
            self.startDate = Date()
            self.waveform.play(for: self.duration)
            self.playButton.setImage(imageLiteral("pause.fill"), for: .normal)
            AudioManager.shared.player?.play()
        }
        
        func pause() {
            self.waveform.pause()
            self.playButton.setImage(imageLiteral("play.fill"), for: .normal)
            AudioManager.shared.player?.pause()
        }
        
        func continuePlay() {
            self.waveform.play(for: self.duration)
            self.playButton.setImage(imageLiteral("pause.fill"), for: .normal)
            AudioManager.shared.player?.play()
        }
        
        func resetElements() {
            self.startDate = nil
            self.waveform.meteringLevels = []
            self.duration = 0
            self.timeLabel.text = nil
        }
        
    }
    
    class RecordPanel: UIView {
        let recordIndicatorSize: CGFloat = 8
        
        var palette: MDCPalette = .amber
        
        let recordIndicator: UIView = {
            let view = UIView()
            
            view.backgroundColor = .systemRed
            view.layer.masksToBounds = true
            
            return view
        }()
                
        let slideToCancelButton: UIButton = {
            let view = UIButton()

            var configuration = UIButton.Configuration.plain()
            configuration.image = imageLiteral("chevron.left", dimension: 18, forceStrong: false)
            configuration.title = "Slide to cancel".localizeString(
                id: "chat_slide_to_cancel_audio_record",
                arguments: []
            )
            configuration.baseForegroundColor = .secondaryLabel
            configuration.imagePadding = 8
            configuration.contentInsets = .zero
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.systemFont(ofSize: 15, weight: .regular)
                return outgoing
            }
            view.configuration = configuration
            view.tintColor = .secondaryLabel
            view.titleLabel?.numberOfLines = 1

            return view
        }()
        
        let cancelButton: UIButton = {
            let button = UIButton()
            
            button.setTitle("Cancel", for: .normal)
            button.isHidden = true
            button.setTitleColor(.tintColor, for: .normal)
            
            return button
        }()
        
        let timeLabel: UILabel = {
            let label = UILabel(frame: CGRect(width: 72, height: 20))
            
            label.font = UIFont.systemFont(ofSize: 16, weight: .regular)
            label.textColor = .label
            label.text = ""
            
            return label
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        internal var slideToCancelButtonCenter: CGPoint = .zero
        
        internal weak var delegate: XabberInputBarDelegate? = nil
        internal var onCancel: (() -> Void)? = nil
        internal var onStop: (() -> Void)? = nil
        internal var onLock: (() -> Void)? = nil
        internal var onUnlock: (() -> Void)? = nil
        internal var onLockStop: (() -> Void)? = nil
        
        internal func setup() {
            self.backgroundColor = .clear
            self.addSubview(recordIndicator)
            self.addSubview(timeLabel)
            self.addSubview(slideToCancelButton)
            self.addSubview(cancelButton)
            self.cancelButton.addTarget(self, action: #selector(self.onCancelRecordTouchUpInside), for: .touchUpInside)
        }
        
        @objc
        internal func onCancelRecordTouchUpInside(_ sender: UIButton) {
            self.onCancel?()
            self.resetElements()
        }
        
        @objc
        internal func onStopRecordTouchUpInside(_ sender: UIButton) {
            self.onStop?()
        }
        
        final func update() {
            self.recordIndicator.frame = CGRect(
                origin: CGPoint(x: 2, y: 15),
                size: CGSize(square: recordIndicatorSize)
            )
            self.recordIndicator.layer.cornerRadius = recordIndicatorSize / 2
            self.timeLabel.textColor = .label
            self.timeLabel.frame = CGRect(
                origin: CGPoint(x: 24, y: 2),
                size: CGSize(width: 74, height: 34)
            )
            let visualState = RecordingCancelHintVisualPolicy.visualState(translationX: 0)
            self.applySlideToCancelVisualState(visualState)
            self.cancelButton.frame = CGRect(
                origin: CGPoint(x: self.frame.width / 2 - 32, y: 0),
                size: CGSize(width: 108, height: 38)
            )
//            self.cancelButton.center = self.center
//            self.slideToCancelButtonCenter = self.slideToCancelButton.center
        }
        
        func resetElements() {
            self.update()
            let timeInterval: TimeInterval = 0
            self.timeLabel.text = timeInterval.minuteFormatedString
            self.unlock()
            self.slideToCancelButton.isHidden = false
            self.cancelButton.isHidden = true
            self.lockIndicatorIsStop = false
        }
        
        var startDate: Date? = nil
        var updateTimer: Timer? = nil
        var lockIndicatorIsStop: Bool = false
        
        func changeIndicatorToStop() {
            self.onLockStop?()
        }
        
        func resetAndStart() {
            self.startDate = Date()
            let timeInterval: TimeInterval = 0
            self.timeLabel.text = timeInterval.minuteFormatedString
            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: { timer in
                if let date = self.startDate {
                    let currentDate = Date()
                    let timeInterval = currentDate.timeIntervalSince1970 - date.timeIntervalSince1970
//                    DispatchQueue.main.async {
                    self.timeLabel.text = timeInterval.minuteFormatedString
//                    }
                }
            })
            RunLoop.main.add(updateTimer!, forMode: .default)
            self.recordIndicator.alpha = 0.3
            UIView.animate(
                withDuration: 0.5,
                delay: 0.0,
                usingSpringWithDamping: 0.6,
                initialSpringVelocity: 0.3,
                options: [.autoreverse, .repeat]) {
                    self.recordIndicator.alpha = 1.0
                } completion: { _ in
                    
                }
        }
        
        func done() {
            self.updateTimer?.invalidate()
            self.updateTimer = nil
            self.recordIndicator.layer.removeAllAnimations()

        }
        
        func slideToCancel(diffX: CGFloat) {
            let visualState = RecordingCancelHintVisualPolicy.visualState(translationX: diffX)
            self.applySlideToCancelVisualState(visualState)
        }

        private func applySlideToCancelVisualState(_ visualState: RecordingCancelHintVisualState) {
            self.slideToCancelButton.frame = CGRect(
                origin: CGPoint(x: visualState.originX, y: 0),
                size: CGSize(
                    width: max(0, self.bounds.width - visualState.originX),
                    height: 38
                )
            )
            self.slideToCancelButton.alpha = visualState.alpha
        }
        
        func slideToLock(point: CGPoint) {
//            let startPoint = CGPoint(
//                x: self.frame.width + 18,
//                y: self.frame.minY - 88
//            )
//            self.lockIndicator.center = startPoint.offset(by: CGSize(width: 0, height: point.y))
        }
        var lockState: Bool = false
        func lock() {
            if !lockState {
                lockState = true
                self.onLock?()
                FeedbackManager.shared.generate(feedback: .success)
            }
        }
        
        func unlock() {
            if lockState {
                lockState = false
                self.onUnlock?()
                FeedbackManager.shared.generate(feedback: .success)
            }
            
        }
    }
    
    open var accountPalette: MDCPalette = AccountColorManager.colors.first!.palette {
        didSet {
            self.recordPanel.palette = accountPalette
            self.recordAndPlayPanel.palette = accountPalette
            self.recordPanel.update()
            self.recordAndPlayPanel.update()
            self.updateComposerActionColors()
            self.recordButton.setIndicatorColors(
                core: accountPalette.tint600,
                halo: accountPalette.tint500
            )
        }
    }
    
    public var keyboardHeight: CGFloat = 0
    private var screenHeight: CGFloat = 0
    private var includesBottomSafeAreaWhenKeyboardHidden = true
    
    private(set) var currentComposerActionMode: ComposerActionMode = .record
    private var voiceRecordButtonMode: VoiceRecordButtonMode = .record
    private var composerActionTransitionGeneration = 0
    var voiceRecordingInteraction = VoiceRecordingInteractionStateMachine()
    private var voiceRecordingGesture: UILongPressGestureRecognizer?
    private var textSendMenuGesture: UILongPressGestureRecognizer?
    private var lockedVoiceRecordingCancelGesture: UIPanGestureRecognizer?
    private var voiceRecordingGestureStartLocation: CGPoint?
    private var smoothedRecordingMeteringLevel: CGFloat = 0
    private var recordLockButtonAllowsStop = false
    private var recordLockButtonVisualTranslation: CGPoint = .zero
    private var recordLockButtonIconScale: CGFloat = 1
    private var isRecordButtonDetachedChromeHidden = false
    private var isNormalizingTypingAttributes = false
    private var measuredTextViewFittingHeightForInvalidation: CGFloat?

    var isRecordingLockOverlayVisible: Bool {
        !self.recordLockButton.isHidden
    }
    
    final var padding: UIEdgeInsets = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        
    final var textViewPadding: UIEdgeInsets = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    
    /// Returns the most recent size calculated by `calculateIntrinsicContentSize()`
    final override var intrinsicContentSize: CGSize {
        return cachedIntrinsicContentSize
    }
    
    /// The intrinsicContentSize can change a lot so the delegate method
    /// `inputBar(self, didChangeIntrinsicContentTo: size)` only needs to be called
    /// when it's different
    public private(set) var previousIntrinsicContentSize: CGSize?
    
    /// The most recent calculation of the intrinsicContentSize
    private lazy var cachedIntrinsicContentSize: CGSize = calculateIntrinsicContentSize()
    
    /// A boolean that indicates if the maxTextViewHeight has been met. Keeping track of this
    /// improves the performance
    public private(set) var isOverMaxTextViewHeight = false
    
    
    var message: String = ""
    
    enum InputBarState {
        case normal
        case identityVerification
        case updateSignature
        case checkDevices
        case checkOwnDevices
        case checkContactDevices
        case skeleton
        case selection
        case search
        case record
        case recordAndPlay
    }

    private struct LiquidGlassLayoutState: Equatable {
        let bounds: CGRect
        let composerFrame: CGRect
        let contentBounds: CGRect
        let textFieldFrame: CGRect
        let attachButtonFrame: CGRect
        let timerButtonFrame: CGRect
        let recordButtonFrame: CGRect
        let sendButtonFrame: CGRect
        let state: InputBarState
        let actionMode: ComposerActionMode
        let isTextFieldHidden: Bool
        let isAttachHidden: Bool
        let isTimerHidden: Bool
        let isRecordHidden: Bool
        let isSendHidden: Bool
    }

    private var lastLiquidGlassLayoutState: LiquidGlassLayoutState?
    
    private var textViewHeightAnchor: NSLayoutConstraint?
    private var didActivateComposerConstraints = false
    private var mainInputHeightConstraint: NSLayoutConstraint?
    private var mainInputLeadingToRootConstraint: NSLayoutConstraint?
    private var mainInputLeadingToAttachConstraint: NSLayoutConstraint?
    private var mainInputTrailingToRootConstraint: NSLayoutConstraint?
    private var mainInputTrailingToTimerConstraint: NSLayoutConstraint?
    private var mainInputTrailingToRecordConstraint: NSLayoutConstraint?
    private var contentViewTopToGlassConstraint: NSLayoutConstraint?
    private var contentViewTopToContextPreviewConstraint: NSLayoutConstraint?
    private var textFieldTrailingToContentConstraint: NSLayoutConstraint?
    private var textFieldTrailingToScheduledButtonConstraint: NSLayoutConstraint?
    private var textFieldTrailingToSendButtonConstraint: NSLayoutConstraint?
    private var lastWidthForRecordingButtonReset: CGFloat = .nan

    private enum RecordingDragVisualPolicy {
        static let minX: CGFloat = -120
        static let maxX: CGFloat = 0
        static let minY: CGFloat = -108
        static let maxY: CGFloat = 0
        static let activationThreshold: CGFloat = 12
        static let catchUpDistance: CGFloat = 24

        static func clamped(_ translation: CGPoint) -> CGPoint {
            CGPoint(
                x: stabilizedAxis(translation.x, minimum: minX, maximum: maxX),
                y: stabilizedAxis(translation.y, minimum: minY, maximum: maxY)
            )
        }

        private static func stabilizedAxis(
            _ value: CGFloat,
            minimum: CGFloat,
            maximum: CGFloat
        ) -> CGFloat {
            let clampedValue = min(max(value, minimum), maximum)
            let distance = -clampedValue
            guard distance > activationThreshold else { return 0 }
            guard distance < catchUpDistance else { return clampedValue }

            let progress = (distance - activationThreshold)
                / (catchUpDistance - activationThreshold)
            return -(catchUpDistance * progress)
        }
    }

    /// The maximum height that the InputTextView can reach
    final var maxTextViewHeight: CGFloat = 130 {
        didSet {
            textViewHeightAnchor?.constant = maxTextViewHeight
            invalidateIntrinsicContentSize()
        }
    }
    
    /// The height that will fit the current text in the InputTextView based on its current bounds
    
    private var inputTextViewMaxWidth: CGFloat = 326.0

    private var composerTextVerticalPadding: CGFloat {
        LiquidGlassMetrics.textVerticalInset * 2
    }

    private var singleLineTextViewHeight: CGFloat {
        let font = textField.font ?? UIFont.preferredFont(forTextStyle: .body)
        return font.lineHeight
            + textField.textContainerInset.top
            + textField.textContainerInset.bottom
            + (textField.textContainer.lineFragmentPadding * 2)
    }

    private var singleLineComposerHeight: CGFloat {
        self.singleLineTextViewHeight + self.composerTextVerticalPadding
    }

    private var collapsedHeightTolerance: CGFloat {
        // Small measurement jitter guard when the one-line text surface height is computed.
        1.0
    }

    private var requiredTextViewFittingHeight: CGFloat {
        let fittingWidth = textField.bounds.width > 0 ? textField.bounds.width : inputTextViewMaxWidth
        let maxTextViewSize = CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
        return textField.sizeThatFits(maxTextViewSize).height.rounded(.down)
    }
    
    public var requiredInputTextViewHeight: CGFloat {
        self.requiredInputTextViewHeight(fittingHeight: self.requiredTextViewFittingHeight)
    }

    private func requiredInputTextViewHeight(fittingHeight: CGFloat) -> CGFloat {
        if isSelectionPanelShowed {
            return ModernXabberInputView.minimumComposerHeight
        }
        let textViewHeight = min(fittingHeight, self.maxTextViewHeight)
        return self.normalizedComposerContentHeight(
            for: textViewHeight + self.composerTextVerticalPadding
        )
    }

    private func normalizedComposerContentHeight(for rawHeight: CGFloat) -> CGFloat {
        let collapsedReferenceHeight = self.singleLineComposerHeight + self.collapsedHeightTolerance

        if rawHeight <= collapsedReferenceHeight {
            return ModernXabberInputView.minimumComposerHeight
        }
        return max(ModernXabberInputView.minimumComposerHeight, rawHeight)
    }
    
    private let mainInputShadowView: UIView = {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = true
        view.layer.shadowColor = nil
        view.layer.shadowOpacity = 0
        view.layer.shadowRadius = 0
        view.layer.shadowOffset = .zero
        view.layer.shadowPath = nil
        return view
    }()

    private let mainInputGlassView: UIVisualEffectView = {
        let view = ModernXabberInputView.makeGlassEffectView(
            role: .clearInputSurface,
            interactive: true
        )
        ModernXabberInputView.applyToolbarGlassLayer(to: view)
        return view
    }()

    let textField: InputTextView = {
        let field = InputTextView(frame: .zero)
        field.accessibilityIdentifier = "chat.composer.text_field"
        
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        field.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
        field.backgroundColor = .clear
        field.layer.cornerRadius = 0
        field.layer.borderWidth = 0
        field.layer.borderColor = UIColor.clear.cgColor
        field.layer.masksToBounds = false
        field.placeholderTextColor = .secondaryLabel
        field.alpha = 1.0
        
        return field
    }()
    
    class RecordButton: UIButton {
        private enum PulseMetrics {
            static let collapsedCenter = CGPoint(x: 22, y: 19)
            static let expandedSize = CGSize(
                width: RecordingGlowMetrics.envelopeSize,
                height: RecordingGlowMetrics.envelopeSize
            )
        }

        private weak var pulseHostView: UIView?
        private var isPulseExpanded: Bool = false
        private(set) var recordingVisualTranslation: CGPoint = .zero

        let pulseView: UIView = {
            let view = UIView(frame: .zero)

            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            view.clipsToBounds = false
            view.layer.masksToBounds = false

            return view
        }()

        let recordingHaloView: UIView = {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            view.isAccessibilityElement = false
            return view
        }()

        let recordingCoreView: UIView = {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            view.isAccessibilityElement = false
            return view
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.pulseView.addSubview(self.recordingHaloView)
            self.pulseView.addSubview(self.recordingCoreView)
            self.addSubview(self.pulseView)
            self.sendSubviewToBack(self.pulseView)
            self.pulseView.frame = self.collapsedPulseFrame()
            self.pulseView.isHidden = true
            self.setIndicatorColors(core: .systemBlue, halo: .systemBlue)
            self.resetPulseGlow()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func hostPulseOverlay(in hostView: UIView) {
            guard self.pulseHostView !== hostView else {
                self.updatePulseOverlayPosition()
                return
            }

            self.pulseHostView = hostView
            self.pulseView.removeFromSuperview()
            hostView.addSubview(self.pulseView)
            self.updatePulseOverlayPosition()
        }

        func setRecordingVisualTranslation(_ translation: CGPoint, animated: Bool = false) {
            guard self.recordingVisualTranslation != translation else {
                self.updatePulseOverlayPosition()
                return
            }
            self.recordingVisualTranslation = translation
            self.pulseView.layer.removeAllAnimations()
            self.layer.removeAllAnimations()

            let updates = {
                self.transform = CGAffineTransform(
                    translationX: translation.x,
                    y: translation.y
                )
                self.updatePulseOverlayPosition()
            }
            guard animated else {
                updates()
                return
            }

            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: updates
            )
        }

        func showPulse() {
            self.isPulseExpanded = true
            self.tintColor = .white
            self.pulseView.layer.removeAllAnimations()
            self.pulseView.isHidden = false
            self.pulseView.layer.masksToBounds = false
            self.pulseView.clipsToBounds = false
            self.updatePulseOverlayPosition()
            self.recordingCoreView.transform = CGAffineTransform(
                scaleX: LiquidGlassMetrics.buttonSize / RecordingGlowMetrics.coreSize,
                y: LiquidGlassMetrics.buttonSize / RecordingGlowMetrics.coreSize
            )
            self.recordingHaloView.transform = CGAffineTransform(
                scaleX: LiquidGlassMetrics.buttonSize / RecordingGlowMetrics.haloSize,
                y: LiquidGlassMetrics.buttonSize / RecordingGlowMetrics.haloSize
            )
            self.recordingHaloView.alpha = 0
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                usingSpringWithDamping: 0.78,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: {
                    self.recordingCoreView.transform = .identity
                    self.recordingHaloView.transform = .identity
                    self.recordingHaloView.alpha = RecordingGlowMetrics.minimumHaloAlpha
                }
            )
        }

        func hidePulse() {
            self.isPulseExpanded = false
            self.pulseView.layer.removeAllAnimations()
            self.pulseView.isHidden = true
            self.pulseView.layer.masksToBounds = false
            self.resetPulseGlow()
            self.updatePulseOverlayPosition()
        }

        func setIndicatorColors(core: UIColor, halo: UIColor) {
            self.recordingCoreView.backgroundColor = core
            self.recordingHaloView.backgroundColor = halo
        }

        func updatePulseGlow(level: CGFloat, color: UIColor, animated: Bool) {
            let clampedLevel = min(max(level, 0), 1)
            let coreScale = 1 + (
                RecordingGlowMetrics.maximumCoreSize / RecordingGlowMetrics.coreSize - 1
            ) * clampedLevel
            let haloScale = 1 + (
                RecordingGlowMetrics.maximumHaloSize / RecordingGlowMetrics.haloSize - 1
            ) * clampedLevel
            let haloAlpha = RecordingGlowMetrics.minimumHaloAlpha
                + (RecordingGlowMetrics.maximumHaloAlpha - RecordingGlowMetrics.minimumHaloAlpha) * clampedLevel

            let updates = {
                self.recordingCoreView.transform = CGAffineTransform(scaleX: coreScale, y: coreScale)
                self.recordingHaloView.transform = CGAffineTransform(scaleX: haloScale, y: haloScale)
                self.recordingHaloView.alpha = haloAlpha
                self.recordingHaloView.backgroundColor = color
            }

            guard animated else {
                updates()
                return
            }

            UIView.animate(
                withDuration: RecordingGlowMetrics.animationDuration,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: updates
            )
        }

        func resetPulseGlow() {
            self.recordingCoreView.layer.removeAllAnimations()
            self.recordingHaloView.layer.removeAllAnimations()
            self.recordingCoreView.transform = .identity
            self.recordingHaloView.transform = .identity
            self.recordingHaloView.alpha = RecordingGlowMetrics.minimumHaloAlpha
            self.pulseView.layer.shadowColor = nil
            self.pulseView.layer.shadowOpacity = 0
            self.pulseView.layer.shadowRadius = 0
            self.pulseView.layer.shadowOffset = .zero
            self.pulseView.layer.shadowPath = nil
        }

        func updatePulseOverlayPosition() {
            guard self.pulseView.superview != nil else { return }

            self.pulseView.frame = self.isPulseExpanded && !self.pulseView.isHidden
                ? self.expandedPulseFrame()
                : self.collapsedPulseFrame()
            if !self.pulseView.bounds.isEmpty {
                self.pulseView.layer.cornerRadius = min(self.pulseView.bounds.width, self.pulseView.bounds.height) / 2
            }
            self.layoutPulseContent()
            if self.isPulseExpanded && !self.pulseView.isHidden {
                self.updatePulseOverlayZOrder()
            }
        }

        private func collapsedPulseFrame() -> CGRect {
            CGRect(origin: self.convertToPulseSuperview(PulseMetrics.collapsedCenter, for: self.pulseView), size: .zero)
        }

        private func expandedPulseFrame() -> CGRect {
            let center = self.convertToPulseSuperview(PulseMetrics.collapsedCenter, for: self.pulseView)
            return CGRect(
                x: center.x - PulseMetrics.expandedSize.width / 2,
                y: center.y - PulseMetrics.expandedSize.height / 2,
                width: PulseMetrics.expandedSize.width,
                height: PulseMetrics.expandedSize.height
            )
        }

        private func convertToPulseSuperview(_ point: CGPoint, for view: UIView) -> CGPoint {
            if let superview = view.superview, superview !== self {
                return self.convert(point, to: superview)
            }
            return point
        }

        private func layoutPulseContent() {
            let center = CGPoint(x: self.pulseView.bounds.midX, y: self.pulseView.bounds.midY)
            let sizes: [(UIView, CGFloat)] = [
                (self.recordingHaloView, RecordingGlowMetrics.haloSize),
                (self.recordingCoreView, RecordingGlowMetrics.coreSize)
            ]
            sizes.forEach { subview, size in
                subview.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                subview.center = center
                subview.layer.cornerRadius = size / 2
                subview.layer.cornerCurve = .continuous
                subview.clipsToBounds = true
            }
        }

        private func updatePulseOverlayZOrder() {
            guard let superview = self.pulseView.superview else { return }
            if superview === self {
                self.sendSubviewToBack(self.pulseView)
            } else if self.superview === superview {
                superview.insertSubview(self.pulseView, belowSubview: self)
            } else {
                superview.bringSubviewToFront(self.pulseView)
            }
        }
    }

    let recordButton: RecordButton = {
        let button = RecordButton(frame: CGRect(square: ModernXabberInputView.LiquidGlassMetrics.buttonSize))

        button.setImage(ModernXabberInputView.composerActionButtonImage(for: .record), for: .normal)
        button.tintColor = .secondaryLabel
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "chat.composer.record_button"
        button.accessibilityLabel = "Record voice message".localizeString(
            id: "chat_composer_record_voice_message_accessibility",
            arguments: []
        )
        button.accessibilityHint = "Hold to record, slide left to cancel, or slide up to lock".localizeString(
            id: "chat_composer_record_voice_message_hint",
            arguments: []
        )
        ModernXabberInputView.applyDetachedGlassButtonStyle(to: button)

        return button
    }()

    let sendButton: UIButton = {
        let button = UIButton(frame: CGRect(square: ModernXabberInputView.LiquidGlassMetrics.buttonSize))

        button.setImage(ModernXabberInputView.composerActionButtonImage(for: .textSend), for: .normal)
        button.tintColor = .secondaryLabel
        button.backgroundColor = .clear
        button.isHidden = true
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "chat.composer.send_button"
        button.accessibilityLabel = "Send message".localizeString(
            id: "chat_composer_send_message_accessibility",
            arguments: []
        )
        ModernXabberInputView.removeChrome(from: button)

        return button
    }()

    let attachButton: UIButton = {
        let button = UIButton(frame: CGRect(square: ModernXabberInputView.LiquidGlassMetrics.buttonSize))

        button.setImage(ModernXabberInputView.composerAttachmentButtonImage(), for: .normal)
        button.tintColor = .secondaryLabel
        ModernXabberInputView.applyDetachedGlassButtonStyle(to: button)
        
        return button
    }()
    
    let timerButton: UIButton = {
        let button = UIButton(frame: CGRect(square: ModernXabberInputView.LiquidGlassMetrics.buttonSize))
        
        button.setImage(imageLiteral("stopwatch", dimension: NativeGlassBarStyle.iconSize), for: .normal)
        button.tintColor = .secondaryLabel
        button.isEnabled = true
        ModernXabberInputView.applyDetachedGlassButtonStyle(to: button)
//        button.isHidden = true
        
        return button
    }()

    let recordLockButton: UIButton = {
        let button = UIButton(frame: CGRect(square: ModernXabberInputView.LiquidGlassMetrics.buttonSize))

        let configuration = UIImage.SymbolConfiguration(pointSize: NativeGlassBarStyle.iconSize, weight: .regular)
        button.setImage(UIImage(systemName: "lock.open.fill", withConfiguration: configuration), for: .normal)
        button.tintColor = .secondaryLabel
        button.isHidden = true
        button.isAccessibilityElement = true
        ModernXabberInputView.applyDetachedGlassButtonStyle(to: button)

        return button
    }()

    let contentView: UIView = {
        let view = UIView(frame: .zero)
        
        return view
    }()

    let scheduledMessagesButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(ModernXabberInputView.makeScheduledMessagesButtonImage(), for: .normal)
        button.tintColor = .secondaryLabel
        button.isHidden = true
        button.isEnabled = false
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = true
        button.accessibilityElementsHidden = true
        button.accessibilityLabel = "Scheduled Messages".localizeString(id: "scheduled_messages_title", arguments: [])
        button.accessibilityIdentifier = "chat.schedule.composer_button"
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.imageView?.contentMode = .scaleAspectFit
        ModernXabberInputView.removeChrome(from: button)
        return button
    }()
    
    let stateButton: UIButton = {
        let button = UIButton()
        
        button.backgroundColor = .clear
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.textColor = .systemBlue
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        button.isHidden = true
        ModernXabberInputView.removeChrome(from: button)
        
        return button
    }()
    
    internal let selectionPanel: SelectionPanel = {
        let width = NativeGlassBarStyle.buttonSize * 5 + NativeGlassBarStyle.contentInset * 2
        let view = SelectionPanel(frame: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: NativeGlassBarStyle.minimumHeight
        ))
        
        view.isHidden = true
        return view
    }()
    
    internal let recordPanel: RecordPanel = {
        let view = RecordPanel(frame: .zero)
        
        view.isHidden = true
        
        return view
    }()
    
    internal let recordAndPlayPanel: RecordAndPlayPanel = {
        let view = RecordAndPlayPanel(frame: .zero)
        
        view.isHidden = true
        
        return view
    }()
    
    internal let searchPanel: SearchPanel = {
        let view = SearchPanel(frame: CGRect(
            x: 0,
            y: 0,
            width: 220,
            height: NativeGlassBarStyle.minimumHeight
        ))
        
        view.isHidden = true
        view.acceptsComposerHitTesting = false
        view.isUserInteractionEnabled = false
        
        return view
    }()

    internal let mentionPanel: MentionSuggestionsPanel = {
        let view = MentionSuggestionsPanel(frame: CGRect(x: 0, y: 0, width: 220, height: 84))
        view.isHidden = true
        return view
    }()
    
    let contextPreviewPanel: ComposerContextPreviewView = {
        let view = ComposerContextPreviewView(frame: .zero)
        
        view.backgroundColor = .clear
        view.isHidden = true
        
        return view
    }()
    
    public weak var delegate: XabberInputBarDelegate? = nil {
        didSet {
            self.recordAndPlayPanel.delegate = self.delegate
            self.recordPanel.delegate = self.delegate
        }
    }

    var mentionConversationType: ClientSynchronizationManager.ConversationType = .regular
    var mentionCandidatesProvider: ((String) -> [ComposerMentionCandidate])? = nil
    var mentionMembersCountProvider: (() -> Int)? = nil
    var mentionUsersReloadHandler: (() -> Void)? = nil
    private var currentMentionQuery: ComposerMentionQueryState? = nil
    private var isMentionUsersReloadInFlight: Bool = false
    private var isApplyingComposerMutation: Bool = false
    
    public var barHeight: CGFloat = ModernXabberInputView.defaultBarHeight

    var sendOptionsMenuSourceView: UIView {
        self.mainInputShadowView
    }

    func trailingActionFrame(in targetView: UIView) -> CGRect? {
        let actionView: UIView
        switch self.state {
        case .normal:
            actionView = self.currentComposerActionMode == .textSend
                ? self.sendButton
                : self.recordButton
        case .record, .recordAndPlay:
            actionView = self.recordButton
        case .identityVerification, .updateSignature, .checkDevices, .checkOwnDevices,
             .checkContactDevices, .skeleton, .selection, .search:
            return nil
        }
        guard actionView.superview != nil,
              !actionView.isHidden,
              actionView.bounds.width > 0,
              actionView.bounds.height > 0 else {
            return nil
        }
        return actionView.convert(actionView.bounds, to: targetView)
    }

    var hasScheduledMessagesForCurrentChat: Bool = false {
        didSet {
            self.updateScheduledMessagesButtonVisibility()
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setup()
        self.activateConstraints()
        self.setupFrames(frame)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setup()
        self.activateConstraints()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard self.superview != nil else {
            self.mentionPanel.removeFromSuperview()
            return
        }
    }

    private func mentionPanelHitView(for point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !self.mentionPanel.isHidden,
              self.mentionPanel.alpha > 0.01,
              self.mentionPanel.isUserInteractionEnabled else {
            return nil
        }

        let mentionPoint = self.mentionPanel.convert(point, from: self)
        return self.mentionPanel.hitTest(mentionPoint, with: event)
    }

    private func recordButtonPulseHitView(for point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !self.recordButton.isHidden,
              self.recordButton.isEnabled,
              self.recordButton.alpha > 0.01,
              !self.recordButton.pulseView.isHidden,
              self.recordButton.pulseView.alpha > 0.01 else {
            return nil
        }

        let pulseFrame = self.recordButton.pulseView
            .convert(self.recordButton.pulseView.bounds, to: self)
            .insetBy(dx: -8, dy: -8)
        return pulseFrame.contains(point) ? self.recordButton : nil
    }

    private func recordLockButtonHitView(for point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !self.recordLockButton.isHidden,
              self.recordLockButton.alpha > 0.01,
              self.recordLockButton.isUserInteractionEnabled else {
            return nil
        }

        let lockPoint = self.recordLockButton.convert(point, from: self)
        return self.recordLockButton.hitTest(lockPoint, with: event)
    }

    private func searchPanelExpandedHitView(
        for point: CGPoint,
        with event: UIEvent?
    ) -> UIView? {
        guard self.state == .search,
              !searchPanel.isHidden,
              searchPanel.isUserInteractionEnabled,
              searchPanel.alpha > 0.01 else {
            return nil
        }
        let panelPoint = searchPanel.convert(point, from: self)
        return searchPanel.expandedCalendarHitView(for: panelPoint, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event)
            || self.searchPanelExpandedHitView(for: point, with: event) != nil
            || self.mentionPanelHitView(for: point, with: event) != nil
            || self.recordLockButtonHitView(for: point, with: event) != nil
            || self.recordButtonPulseHitView(for: point, with: event) != nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.isUserInteractionEnabled, !self.isHidden, self.alpha > 0.01 else {
            return nil
        }

        if let mentionHitView = self.mentionPanelHitView(for: point, with: event) {
            return mentionHitView
        }

        if let searchHitView = self.searchPanelExpandedHitView(for: point, with: event) {
            return searchHitView
        }

        if let pulseHitView = self.recordButtonPulseHitView(for: point, with: event) {
            return pulseHitView
        }

        if let lockHitView = self.recordLockButtonHitView(for: point, with: event) {
            return lockHitView
        }

        return super.hitTest(point, with: event)
    }

    private func attachMentionPanelIfNeeded() {
        guard let superview = self.superview else { return }
        if self.mentionPanel.superview !== superview {
            self.mentionPanel.removeFromSuperview()
            superview.addSubview(self.mentionPanel)
        }
        superview.bringSubviewToFront(self.mentionPanel)
    }
    
    private func addObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewDidChange),
            name: UITextView.textDidChangeNotification, object: textField
        )
    }

    private func updateComposerControlLayout() {
        let shouldLeadToAttach = !self.attachButton.isHidden
        let shouldLayoutRecord: Bool
        switch self.state {
        case .normal:
            shouldLayoutRecord = self.currentComposerActionMode == .record
        case .record, .recordAndPlay:
            shouldLayoutRecord = true
        case .identityVerification, .updateSignature, .checkDevices, .checkOwnDevices,
             .checkContactDevices, .skeleton, .selection, .search:
            shouldLayoutRecord = false
        }
        let shouldTrailToTimer = !self.timerButton.isHidden && shouldLayoutRecord
        let shouldTrailToRecord = !shouldTrailToTimer && shouldLayoutRecord

        self.setConstraint(self.mainInputLeadingToAttachConstraint, active: shouldLeadToAttach)
        self.setConstraint(self.mainInputLeadingToRootConstraint, active: !shouldLeadToAttach)
        self.setConstraint(self.mainInputTrailingToTimerConstraint, active: shouldTrailToTimer)
        self.setConstraint(self.mainInputTrailingToRecordConstraint, active: shouldTrailToRecord)
        self.setConstraint(
            self.mainInputTrailingToRootConstraint,
            active: !shouldTrailToTimer && !shouldTrailToRecord
        )

        self.updateTextFieldTrailingConstraint()
        self.setConstraint(
            self.mainInputHeightConstraint,
            constant: self.currentComposerContentHeight() + self.topInset
        )
        self.startPositionRecordButton = self.recordButton.center
    }

    private func updateTextFieldTrailingConstraint() {
        let shouldTrailToSend = self.state == .normal && self.currentComposerActionMode == .textSend
        let shouldTrailToScheduled = !shouldTrailToSend && !self.scheduledMessagesButton.isHidden

        self.setConstraint(self.textFieldTrailingToSendButtonConstraint, active: shouldTrailToSend)
        self.setConstraint(self.textFieldTrailingToScheduledButtonConstraint, active: shouldTrailToScheduled)
        self.setConstraint(
            self.textFieldTrailingToContentConstraint,
            active: !shouldTrailToSend && !shouldTrailToScheduled
        )
    }

    private func currentComposerContentHeight() -> CGFloat {
        self.normalizedComposerContentHeight(for: self.cachedIntrinsicContentSize.height)
    }

    private func composerFrame(contentHeight: CGFloat) -> CGRect {
        let rawFrame = CGRect(
            x: 0,
            y: LiquidGlassMetrics.contentTopOffset,
            width: max(0, self.bounds.width),
            height: contentHeight + self.topInset
        ).insetBy(
            dx: LiquidGlassMetrics.composerHorizontalInset,
            dy: LiquidGlassMetrics.composerVerticalInset
        )
        return CGRect(
            x: rawFrame.minX,
            y: rawFrame.minY,
            width: max(0, rawFrame.width),
            height: max(0, rawFrame.height)
        )
    }

    private var isContextPreviewShowed: Bool {
        self.activeContextPreviewMode != nil
    }

    private func layoutContextPreviewPanel() {
        let isShowing = self.isContextPreviewShowed
        if self.contextPreviewPanel.isHidden == isShowing {
            self.contextPreviewPanel.isHidden = !isShowing
        }
        self.setConstraint(self.contentViewTopToContextPreviewConstraint, active: isShowing)
        self.setConstraint(self.contentViewTopToGlassConstraint, active: !isShowing)
        if isShowing {
            self.contextPreviewPanel.update()
        }
    }

    private func setConstraint(_ constraint: NSLayoutConstraint?, active: Bool) {
        guard let constraint, constraint.isActive != active else { return }
        constraint.isActive = active
    }

    private func setConstraint(_ constraint: NSLayoutConstraint?, constant: CGFloat) {
        guard let constraint, constraint.constant != constant else { return }
        constraint.constant = constant
    }

    private func updateComposerContentLayout() {
        self.layoutContextPreviewPanel()
        self.updateComposerControlLayout()
        self.layoutComposerRecordingPanels()
    }

    public func setupFrames(_ frame: CGRect) {
        let isPositionOwnedByAutoLayout =
            !self.translatesAutoresizingMaskIntoConstraints && self.superview != nil
        if !isPositionOwnedByAutoLayout {
            self.frame = frame
        }
        self.updateComposerContentLayout()
        self.backgroundColor = .clear
        self.layoutLiquidGlassAppearance()
        self.updateBottomPanels(withOffset: 0)
        self.selectionPanel.update()
        self.recordPanel.update()
        self.recordAndPlayPanel.update()
    }
    
    final func setup() {
        self.backgroundColor = .clear
        self.clipsToBounds = false
        self.addSubview(self.mainInputShadowView)
        self.mainInputShadowView.addSubview(self.mainInputGlassView)
        self.addSubview(self.attachButton)
        self.addSubview(self.timerButton)
        self.addSubview(self.recordButton)
        self.addSubview(self.recordLockButton)
        self.mainInputShadowView.clipsToBounds = false
        self.contentView.backgroundColor = .clear
        self.contentView.isUserInteractionEnabled = true
        [
            self.mainInputShadowView,
            self.mainInputGlassView,
            self.contextPreviewPanel,
            self.contentView,
            self.attachButton,
            self.textField,
            self.scheduledMessagesButton,
            self.timerButton,
            self.sendButton,
            self.recordButton,
            self.recordLockButton
        ].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        self.scheduledMessagesButton.setContentHuggingPriority(.required, for: .horizontal)
        self.scheduledMessagesButton.setContentHuggingPriority(.required, for: .vertical)
        self.scheduledMessagesButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.scheduledMessagesButton.setContentCompressionResistancePriority(.required, for: .vertical)
        self.mainInputGlassView.contentView.addSubview(self.contextPreviewPanel)
        self.mainInputGlassView.contentView.addSubview(self.contentView)
        self.contentView.addSubview(self.textField)
        self.contentView.addSubview(self.scheduledMessagesButton)
        self.contentView.addSubview(self.sendButton)
        self.contentView.addSubview(self.stateButton)
        self.contentView.addSubview(self.recordAndPlayPanel)
        self.contentView.addSubview(self.recordPanel)
        self.contentView.bringSubviewToFront(self.sendButton)
        self.contentView.bringSubviewToFront(self.stateButton)
        self.bringSubviewToFront(self.attachButton)
        self.bringSubviewToFront(self.timerButton)
        self.bringSubviewToFront(self.recordButton)
        self.bringSubviewToFront(self.recordLockButton)
        
        [
            self.stateButton
        ].forEach { ModernXabberInputView.removeChrome(from: $0) }
        self.refreshDetachedComposerButtonChrome(forceConfigurationUpdate: false)
        self.textField.backgroundColor = .clear
        self.textField.layer.borderWidth = 0
        self.textField.layer.borderColor = UIColor.clear.cgColor
        
        self.addSubview(self.selectionPanel)
        self.addSubview(self.searchPanel)
        self.bringSubviewToFront(searchPanel)
        self.recordButton.hostPulseOverlay(in: self)
        
        self.stateButton.fillSuperview()
        self.stateButton.isHidden = true
        self.textField.delegate = self
        self.textField.keyHandler = self
        self.textField.typingAttributes = self.baseComposerAttributes()
        self.addObservers()
        self.attachButton.addTarget(self, action: #selector(self.onAttachButtonTouchDown), for: .touchDown)
        self.attachButton.addTarget(self, action: #selector(self.onAttachButtonTouchUp), for: .touchUpInside)
        self.timerButton.addTarget(self,  action: #selector(self.onTimerButtonTouchUp), for: .touchUpInside)
        self.recordButton.addTarget(self, action: #selector(self.onRecordButtonTouchUp), for: .touchUpInside)
        self.sendButton.addTarget(self, action: #selector(self.onTextSendButtonTouchUp), for: .touchUpInside)
        self.scheduledMessagesButton.addTarget(self, action: #selector(self.onScheduledMessagesButtonTouchUp), for: .touchUpInside)
        self.recordLockButton.addTarget(self, action: #selector(self.onRecordLockButtonTouchUp), for: .touchUpInside)
        self.stateButton.addTarget(self,  action: #selector(self.onStateButtonTouchUp), for: .touchUpInside)
        self.recordPanel.onCancel = { [weak self] in
            self?.cancelActiveVoiceRecordingFromControl()
        }
        self.recordPanel.onStop = { [weak self] in
            self?.stopLockedAudioRecording()
        }
        self.recordPanel.onLock = { [weak self] in
            self?.showRecordingLockOverlay(isLocked: true, allowsStop: true, animated: true)
        }
        self.recordPanel.onUnlock = { [weak self] in
            self?.showRecordingLockOverlay(isLocked: false, allowsStop: false, animated: true)
        }
        self.recordPanel.onLockStop = { [weak self] in
            self?.showRecordingLockOverlay(isLocked: true, allowsStop: true, animated: true)
        }
        self.recordAndPlayPanel.onDelete = { [weak self] in
            self?.deleteVoiceRecordingPreview()
        }
        self.recordAndPlayPanel.onPlay = { [weak self] in
            self?.playVoiceRecordingPreview()
        }
        self.mentionPanel.onSelect = { [weak self] item in
            self?.insertMentionCandidate(item)
        }
        self.contextPreviewPanel.update(title: "title", normal: "message")
        self.contextPreviewPanel.configureForForward()
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(voiceRecordingLongPressGesture(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = CGFloat.greatestFiniteMagnitude
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        self.voiceRecordingGesture = gesture
        self.recordButton.gestureRecognizers?.forEach {
            self.recordButton.removeGestureRecognizer($0)
        }
        self.recordButton.addGestureRecognizer(gesture)

        let textMenuGesture = UILongPressGestureRecognizer(target: self, action: #selector(textSendMenuLongPressGesture(_:)))
        textMenuGesture.minimumPressDuration = 0.45
        textMenuGesture.cancelsTouchesInView = true
        textMenuGesture.delegate = self
        self.textSendMenuGesture = textMenuGesture
        self.sendButton.addGestureRecognizer(textMenuGesture)

        let lockedCancelGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(self.lockedVoiceRecordingCancelPanGesture(_:))
        )
        lockedCancelGesture.cancelsTouchesInView = true
        lockedCancelGesture.delegate = self
        self.lockedVoiceRecordingCancelGesture = lockedCancelGesture
        self.addGestureRecognizer(lockedCancelGesture)
    }
    
    
    
    public var state: InputBarState = .normal {
        didSet {
            print("change state to \(self.state)")
        }
    }
    
    public var shouldHideTimer: Bool = true {
        didSet {
            self.changeState(to: self.state)
        }
    }
    
    public func changeState(to state: InputBarState) {
        if state != .normal {
            self.hideMentionSuggestions()
        }
        switch state {
            case .normal:
                self.state = state
                self.attachButton.isHidden =    false
                self.textField.isHidden =       false
                self.timerButton.isHidden =     self.shouldHideTimer
                self.recordButton.isHidden =    self.currentComposerActionMode == .textSend
                self.sendButton.isHidden =      self.currentComposerActionMode != .textSend
                self.stateButton.isHidden =     true
//                self.recordButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
            case .updateSignature:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.recordButton.isHidden =    true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
//                self.recordButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
                self.stateButton.setTitle("Update signature", for: .normal)
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .identityVerification:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.recordButton.isHidden =    true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
                self.searchPanel.isHidden =     true
//                self.recordButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.stateButton.setTitle("Identity verification", for: .normal)
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .checkDevices, .checkOwnDevices, .checkContactDevices:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.recordButton.isHidden =    true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
                self.searchPanel.isHidden =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                switch state {
                case .checkContactDevices:
                    self.stateButton.setTitle("Check contact’s devices", for: .normal)
                default:
                    self.stateButton.setTitle("Check my devices", for: .normal)
                }
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .skeleton:
                self.state = state
                self.recordButton.isHidden =    true
                self.sendButton.isHidden =      true
//                self.recordButton.isEnabled =     false
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
            case .selection:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.recordButton.isHidden =    true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  false
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
            case .search:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.recordButton.isHidden =    true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     false
            case .record:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.recordButton.isHidden =    false
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     false
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
            case .recordAndPlay:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.recordButton.isHidden =    false
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = false
                self.searchPanel.isHidden =     true
                
        }
        self.composerActionTransitionGeneration += 1
        [self.recordButton, self.sendButton].forEach {
            $0.layer.removeAllAnimations()
            $0.alpha = 1
            $0.transform = .identity
        }
        self.setNeedsLayout()
        if state != .record {
            self.resetRecordingOverlayVisuals()
        }
        self.resetRecordingButtonPositionAndVisibility(animated: false)
        self.updateScheduledMessagesButtonVisibility()
        self.synchronizeSearchPanelInteractivity()
    }

    private func synchronizeSearchPanelInteractivity() {
        let isSearchActive = self.state == .search
        self.searchPanel.acceptsComposerHitTesting = isSearchActive
        self.searchPanel.isUserInteractionEnabled = isSearchActive
        self.searchPanel.isHidden = !isSearchActive
    }
    
    var isSelectionPanelShowed: Bool = false
    
    public func showSelectionPanel() {
        self.textField.resignFirstResponder()
        self.isSelectionPanelShowed = true
        self.invalidateIntrinsicContentSize()
        self.attachButton.isHidden =    true
        self.textField.isHidden =       true
        self.timerButton.isHidden =     true
        self.recordButton.isHidden =    true
        self.sendButton.isHidden =      true
        self.stateButton.isHidden =     true
        self.selectionPanel.isHidden =  false
    }
    
    public func hideSelectionPanel() {
        self.isSelectionPanelShowed = false
        self.invalidateIntrinsicContentSize()
        self.changeState(to: self.state)
    }
    
    var topInset: CGFloat = 0
    var activeContextPreviewMode: ComposerContextPreviewView.Mode? = nil

    private func resolvedInputHeight(keyboardHeight: CGFloat) -> CGFloat {
        Self.resolvedContainerHeight(
            barHeight: self.barHeight,
            keyboardHeight: keyboardHeight,
            topInset: self.topInset,
            bottomSafeAreaInset: self.applicationBottomSafeAreaInset,
            includeBottomSafeAreaWhenKeyboardHidden: self.includesBottomSafeAreaWhenKeyboardHidden
        )
    }

    private func notifyHeightChangedForCurrentContext() {
        self.barHeight = self.currentComposerContentHeight() + LiquidGlassMetrics.verticalReserve
        let inputHeight = self.resolvedInputHeight(
            keyboardHeight: self.keyboardHeight
        )

        self.delegate?.onHeightChanged(to: inputHeight, bar: 0)
    }
    
    public final func updateBottomPanels(withOffset offset: CGFloat) {
        let selectionWidth = max(
            NativeGlassBarStyle.buttonSize,
            self.bounds.width - NativeGlassBarStyle.horizontalInset * 2
        )
        selectionPanel.frame = CGRect(
            origin: CGPoint(x: NativeGlassBarStyle.horizontalInset, y: offset),
            size: CGSize(
                width: selectionWidth,
                height: NativeGlassBarStyle.minimumHeight
            )
        )
        selectionPanel.update()
        self.layoutComposerRecordingPanels()
        let searchWidth = max(
            NativeGlassBarStyle.buttonSize,
            self.bounds.width
        )
        let searchHeight = ChatSearchBottomActionBarLayout.height
        let searchOriginY = offset + max(
            0,
            (NativeGlassBarStyle.minimumHeight - searchHeight) / 2
        )
        searchPanel.frame = CGRect(
            origin: CGPoint(x: 0, y: searchOriginY),
            size: CGSize(
                width: searchWidth,
                height: searchHeight
            )
        )
        self.layoutMentionPanel()
    }

    private func layoutComposerRecordingPanels() {
        let composerBounds = self.contentView.bounds.width > 0
            ? self.contentView.bounds
            : CGRect(x: 0, y: 0, width: self.bounds.width, height: ModernXabberInputView.minimumComposerHeight)
        let panelFrame = CGRect(
            origin: CGPoint(x: 8, y: max(0, (composerBounds.height - 38) / 2)),
            size: CGSize(width: max(0, composerBounds.width - 16), height: 38)
        )
        if self.recordPanel.frame != panelFrame {
            self.recordPanel.frame = panelFrame
        }
        if self.recordAndPlayPanel.frame != panelFrame {
            self.recordAndPlayPanel.frame = panelFrame
        }
    }
    
    public func showForwardPanel() {
        self.showContextPreview(mode: .forward)
    }
    
    public func hideForwardPanel() {
        self.hideContextPreview(ifActive: .forward)
    }
    
    public func showEditPanel() {
        self.showContextPreview(mode: .edit)
    }

    public func hideEditPanel() {
        self.hideContextPreview(ifActive: .edit)
    }

    private func showContextPreview(mode: ComposerContextPreviewView.Mode) {
        let wasShowingContextPreview = self.isContextPreviewShowed
        self.activeContextPreviewMode = mode
        self.topInset = LiquidGlassMetrics.contextPreviewReservedHeight
        self.contextPreviewPanel.configure(mode: mode)
        self.contextPreviewPanel.isHidden = false
        if wasShowingContextPreview {
            self.layoutContextPreviewPanel()
            return
        }
        self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight, animate: true) {
            self.contextPreviewPanel.update()
            self.contextPreviewPanel.isHidden = false
            self.notifyHeightChangedForCurrentContext()
        }
        
    }

    private func hideContextPreview(ifActive mode: ComposerContextPreviewView.Mode) {
        if self.activeContextPreviewMode != mode {
            return
        }
        self.activeContextPreviewMode = nil
        self.topInset = 0
        self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight, animate: true) {
            self.contextPreviewPanel.isHidden = true
            self.updateBottomPanels(withOffset: 0)
            self.notifyHeightChangedForCurrentContext()
        }
        
    }
    
    final func update(
        screenHeight: CGFloat,
        keyboardHeight: CGFloat,
        includeBottomSafeAreaWhenKeyboardHidden: Bool? = nil,
        animate: Bool = false,
        additionalAnimations: (() -> Void)? = nil
    ) {
        func doAnimate(_ block: @escaping () -> Void) {
            if animate {
                UIView.animate(withDuration: 0.16, delay: 0.0, options: [.showHideTransitionViews, .curveEaseInOut], animations: block)
            } else {
                block()
            }
        }
        
        self.keyboardHeight = keyboardHeight
        self.screenHeight = screenHeight
        if let includeBottomSafeAreaWhenKeyboardHidden {
            self.includesBottomSafeAreaWhenKeyboardHidden =
                includeBottomSafeAreaWhenKeyboardHidden
        }
        let inputHeight = self.resolvedInputHeight(
            keyboardHeight: keyboardHeight
        )
        let isPositionOwnedByAutoLayout =
            !self.translatesAutoresizingMaskIntoConstraints && self.superview != nil
        let targetFrame = CGRect(
            origin: CGPoint(
                x: self.frame.minX,
                y: isPositionOwnedByAutoLayout
                    ? self.frame.minY
                    : screenHeight - inputHeight
            ),
            size: CGSize(width: self.bounds.width, height: inputHeight)
        )
        doAnimate {
            var geometryChanged = false
            if !isPositionOwnedByAutoLayout,
               self.frame != targetFrame {
                self.frame = targetFrame
                geometryChanged = true
            }
//            NSLayoutConstraint.activate([
//                self.heightAnchor.constraint(equalToConstant: inputHeight)
//            ])
            if let heightConstraint = self.heightConstraint,
               heightConstraint.constant != inputHeight {
                heightConstraint.constant = inputHeight
                geometryChanged = true
            }
            if geometryChanged {
                self.updateComposerContentLayout()
                self.layoutMentionPanel()
                self.setNeedsLayout()
            }
            additionalAnimations?()
        }
    }

    open var heightConstraint: NSLayoutConstraint? = nil

    private var applicationBottomSafeAreaInset: CGFloat {
        (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom ?? 0
    }
    
    final func activateConstraints() {
        guard !self.didActivateComposerConstraints else { return }
        self.didActivateComposerConstraints = true

        let mainInputHeight = self.mainInputShadowView.heightAnchor.constraint(equalToConstant: self.currentComposerContentHeight())
        let mainLeadingToRoot = self.mainInputShadowView.leadingAnchor.constraint(equalTo: self.leadingAnchor)
        let mainLeadingToAttach = self.mainInputShadowView.leadingAnchor.constraint(
            equalTo: self.attachButton.trailingAnchor,
            constant: LiquidGlassMetrics.buttonSpacing
        )
        let mainTrailingToRoot = self.mainInputShadowView.trailingAnchor.constraint(equalTo: self.trailingAnchor)
        let mainTrailingToTimer = self.mainInputShadowView.trailingAnchor.constraint(
            equalTo: self.timerButton.leadingAnchor,
            constant: -LiquidGlassMetrics.buttonSpacing
        )
        let mainTrailingToRecord = self.mainInputShadowView.trailingAnchor.constraint(
            equalTo: self.recordButton.leadingAnchor,
            constant: -LiquidGlassMetrics.buttonSpacing
        )
        let contentTopToGlass = self.contentView.topAnchor.constraint(equalTo: self.mainInputGlassView.contentView.topAnchor)
        let contentTopToContextPreview = self.contentView.topAnchor.constraint(
            equalTo: self.contextPreviewPanel.bottomAnchor,
            constant: LiquidGlassMetrics.contextPreviewComposerGap
        )
        let textFieldTrailingToContent = self.textField.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor)
        let textFieldTrailingToScheduledButton = self.textField.trailingAnchor.constraint(
            equalTo: self.scheduledMessagesButton.leadingAnchor,
            constant: -LiquidGlassMetrics.scheduledMessagesButtonTextGap
        )
        let textFieldTrailingToSendButton = self.textField.trailingAnchor.constraint(
            equalTo: self.sendButton.leadingAnchor
        )
        self.mainInputHeightConstraint = mainInputHeight
        self.mainInputLeadingToRootConstraint = mainLeadingToRoot
        self.mainInputLeadingToAttachConstraint = mainLeadingToAttach
        self.mainInputTrailingToRootConstraint = mainTrailingToRoot
        self.mainInputTrailingToTimerConstraint = mainTrailingToTimer
        self.mainInputTrailingToRecordConstraint = mainTrailingToRecord
        self.contentViewTopToGlassConstraint = contentTopToGlass
        self.contentViewTopToContextPreviewConstraint = contentTopToContextPreview
        self.textFieldTrailingToContentConstraint = textFieldTrailingToContent
        self.textFieldTrailingToScheduledButtonConstraint = textFieldTrailingToScheduledButton
        self.textFieldTrailingToSendButtonConstraint = textFieldTrailingToSendButton
        mainLeadingToRoot.isActive = false
        mainTrailingToRoot.isActive = false
        mainTrailingToTimer.isActive = false
        contentTopToContextPreview.isActive = false
        textFieldTrailingToScheduledButton.isActive = false
        textFieldTrailingToSendButton.isActive = false

        NSLayoutConstraint.activate([
            self.mainInputShadowView.topAnchor.constraint(equalTo: self.topAnchor, constant: LiquidGlassMetrics.contentTopOffset),
            mainInputHeight,
            mainLeadingToAttach,
            mainTrailingToRecord,

            self.mainInputGlassView.leadingAnchor.constraint(equalTo: self.mainInputShadowView.leadingAnchor),
            self.mainInputGlassView.trailingAnchor.constraint(equalTo: self.mainInputShadowView.trailingAnchor),
            self.mainInputGlassView.topAnchor.constraint(equalTo: self.mainInputShadowView.topAnchor),
            self.mainInputGlassView.bottomAnchor.constraint(equalTo: self.mainInputShadowView.bottomAnchor),

            self.attachButton.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.attachButton.bottomAnchor.constraint(equalTo: self.mainInputShadowView.bottomAnchor),
            self.attachButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),
            self.attachButton.heightAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),

            self.timerButton.trailingAnchor.constraint(
                equalTo: self.recordButton.leadingAnchor,
                constant: -LiquidGlassMetrics.buttonSpacing
            ),
            self.timerButton.bottomAnchor.constraint(equalTo: self.mainInputShadowView.bottomAnchor),
            self.timerButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),
            self.timerButton.heightAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),

            self.recordButton.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.recordButton.bottomAnchor.constraint(equalTo: self.mainInputShadowView.bottomAnchor),
            self.recordButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),
            self.recordButton.heightAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),

            self.recordLockButton.centerXAnchor.constraint(equalTo: self.recordButton.centerXAnchor),
            self.recordLockButton.bottomAnchor.constraint(
                equalTo: self.recordButton.topAnchor,
                constant: -LiquidGlassMetrics.recordingLockButtonVerticalGap
            ),
            self.recordLockButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),
            self.recordLockButton.heightAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),

            self.contextPreviewPanel.leadingAnchor.constraint(equalTo: self.mainInputGlassView.contentView.leadingAnchor),
            self.contextPreviewPanel.trailingAnchor.constraint(equalTo: self.mainInputGlassView.contentView.trailingAnchor),
            self.contextPreviewPanel.topAnchor.constraint(equalTo: self.mainInputGlassView.contentView.topAnchor),
            self.contextPreviewPanel.heightAnchor.constraint(equalToConstant: ComposerContextPreviewView.height),

            self.contentView.leadingAnchor.constraint(
                equalTo: self.mainInputGlassView.contentView.leadingAnchor,
                constant: LiquidGlassMetrics.textHorizontalInset
            ),
            self.contentView.trailingAnchor.constraint(
                equalTo: self.mainInputGlassView.contentView.trailingAnchor,
                constant: -LiquidGlassMetrics.textHorizontalInset
            ),
            contentTopToGlass,
            self.contentView.bottomAnchor.constraint(equalTo: self.mainInputGlassView.contentView.bottomAnchor),

            self.textField.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor),
            textFieldTrailingToContent,
            self.textField.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: LiquidGlassMetrics.textVerticalInset),
            self.textField.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -LiquidGlassMetrics.textVerticalInset),

            self.sendButton.trailingAnchor.constraint(equalTo: self.mainInputGlassView.contentView.trailingAnchor),
            self.sendButton.bottomAnchor.constraint(equalTo: self.mainInputGlassView.contentView.bottomAnchor),
            self.sendButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),
            self.sendButton.heightAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),

            self.scheduledMessagesButton.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            self.scheduledMessagesButton.topAnchor.constraint(equalTo: self.textField.topAnchor),
            self.scheduledMessagesButton.bottomAnchor.constraint(equalTo: self.textField.bottomAnchor),
            self.scheduledMessagesButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.scheduledMessagesButtonWidth)
        ])

        self.updateComposerControlLayout()
        self.updateScheduledMessagesButtonVisibility()
    }

    override func layoutSubviews() {
        let shouldResetRecordingButton = ComposerRecordingGeometryResetPolicy.shouldReset(
            previousWidth: self.lastWidthForRecordingButtonReset,
            nextWidth: self.bounds.width
        )
        super.layoutSubviews()
        self.synchronizeSearchPanelInteractivity()
        self.layoutLiquidGlassAppearance()
        if shouldResetRecordingButton {
            self.lastWidthForRecordingButtonReset = self.bounds.width
            self.resetRecordingButtonPositionAndVisibility(animated: false, enforceVisibility: false)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        self.updateLiquidGlassColors()
    }

    private func layoutLiquidGlassAppearance() {
        let contentHeight = self.currentComposerContentHeight()
        let shouldHideInput = self.isSelectionPanelShowed
            || self.state == .selection
            || self.state == .search
            || self.state == .skeleton
        if self.mainInputShadowView.isHidden != shouldHideInput {
            self.mainInputShadowView.isHidden = shouldHideInput
        }
        self.setConstraint(self.mainInputHeightConstraint, constant: contentHeight + self.topInset)

        self.restoreComposerActionGlyphs()
        self.updateComposerContentLayout()
        if !self.recordButton.pulseView.isHidden {
            self.recordButton.updatePulseOverlayPosition()
        }
        self.ensureDetachedComposerButtonChrome()
        if !self.recordLockButton.isHidden {
            self.bringSubviewToFront(self.recordLockButton)
        }

        let composerFrame = self.mainInputGlassView.convert(self.mainInputGlassView.bounds, to: self)

        let layoutState = LiquidGlassLayoutState(
            bounds: self.bounds,
            composerFrame: composerFrame,
            contentBounds: self.contentView.bounds,
            textFieldFrame: self.textField.frame,
            attachButtonFrame: self.attachButton.frame,
            timerButtonFrame: self.timerButton.frame,
            recordButtonFrame: self.recordButton.frame,
            sendButtonFrame: self.sendButton.frame,
            state: self.state,
            actionMode: self.currentComposerActionMode,
            isTextFieldHidden: self.textField.isHidden,
            isAttachHidden: self.attachButton.isHidden,
            isTimerHidden: self.timerButton.isHidden,
            isRecordHidden: self.recordButton.isHidden,
            isSendHidden: self.sendButton.isHidden
        )
        guard layoutState != self.lastLiquidGlassLayoutState else { return }
        self.lastLiquidGlassLayoutState = layoutState

        self.updateLiquidGlassColors()
    }

    private func updateLiquidGlassColors() {
        self.textField.backgroundColor = .clear
        self.textField.layer.borderWidth = 0
        self.textField.layer.borderColor = UIColor.clear.cgColor
        self.recordButton.setIndicatorColors(
            core: self.accountPalette.tint600,
            halo: self.accountPalette.tint500
        )
        ModernXabberInputView.removeChrome(from: self.sendButton)
        self.updateComposerActionColors()
        ModernXabberInputView.removeChrome(from: self.scheduledMessagesButton)
        self.restoreScheduledMessagesButtonGlyph()
        self.scheduledMessagesButton.tintColor = .secondaryLabel
        ModernXabberInputView.removeChrome(from: self.stateButton)
    }

    private func setRecordButtonDetachedChromeHidden(_ hidden: Bool) {
        guard self.isRecordButtonDetachedChromeHidden != hidden else { return }
        self.isRecordButtonDetachedChromeHidden = hidden
        self.applyRecordButtonDetachedChromeVisibility()
    }

    private func applyRecordButtonDetachedChromeVisibility() {
        if #available(iOS 26.0, *) {
            if self.isRecordButtonDetachedChromeHidden {
                guard self.recordButton.configuration != nil else { return }
                ModernXabberInputView.setDetachedGlassButtonChromeHidden(true, on: self.recordButton)
            } else {
                guard self.recordButton.configuration == nil else { return }
                ModernXabberInputView.applyDetachedGlassButtonStyle(
                    to: self.recordButton,
                    forceConfigurationUpdate: false
                )
            }
            return
        }

        let effectView = self.recordButton.subviews.compactMap { $0 as? UIVisualEffectView }.first
        if self.isRecordButtonDetachedChromeHidden {
            guard effectView?.isHidden == false else { return }
        } else {
            guard effectView == nil || effectView?.isHidden == true else { return }
        }
        ModernXabberInputView.setDetachedGlassButtonChromeHidden(
            self.isRecordButtonDetachedChromeHidden,
            on: self.recordButton
        )
    }

    private func refreshDetachedComposerButtonChrome(forceConfigurationUpdate: Bool = false) {
        [
            self.attachButton,
            self.timerButton,
            self.recordLockButton
        ].forEach {
            ModernXabberInputView.applyDetachedGlassButtonStyle(
                to: $0,
                forceConfigurationUpdate: forceConfigurationUpdate
            )
        }
        if !self.isRecordButtonDetachedChromeHidden {
            ModernXabberInputView.applyDetachedGlassButtonStyle(
                to: self.recordButton,
                forceConfigurationUpdate: forceConfigurationUpdate
            )
        }
        self.applyRecordButtonDetachedChromeVisibility()
    }

    private func ensureDetachedComposerButtonChrome() {
        let alwaysVisibleChromeButtons = [
            self.attachButton,
            self.timerButton,
            self.recordLockButton
        ]
        alwaysVisibleChromeButtons.forEach { button in
            if self.detachedComposerButtonNeedsChromeRefresh(button) {
                ModernXabberInputView.applyDetachedGlassButtonStyle(
                    to: button,
                    forceConfigurationUpdate: false
                )
            }
        }

        if !self.isRecordButtonDetachedChromeHidden,
           self.detachedComposerButtonNeedsChromeRefresh(self.recordButton) {
            ModernXabberInputView.applyDetachedGlassButtonStyle(
                to: self.recordButton,
                forceConfigurationUpdate: false
            )
        }
        self.applyRecordButtonDetachedChromeVisibility()
    }

    private func detachedComposerButtonNeedsChromeRefresh(_ button: UIButton) -> Bool {
        let isGlyphMissing = button.image(for: .normal) == nil
            && button.configuration?.image == nil
        if isGlyphMissing {
            return true
        }
        if #available(iOS 26.0, *) {
            return button.configuration == nil
        }
        return !button.subviews.contains(where: { $0 is UIVisualEffectView })
    }

    private func restoreScheduledMessagesButtonGlyph() {
        if self.scheduledMessagesButton.image(for: .normal) == nil {
            self.scheduledMessagesButton.setImage(
                ModernXabberInputView.makeScheduledMessagesButtonImage(),
                for: .normal
            )
        }
        self.scheduledMessagesButton.tintColor = .secondaryLabel
        self.scheduledMessagesButton.imageView?.contentMode = .scaleAspectFit
    }

    private func restoreComposerActionGlyphs() {
        if self.recordButton.image(for: .normal) == nil,
           self.recordButton.configuration?.image == nil {
            self.setRecordButtonImage(Self.composerActionButtonImage(
                for: self.voiceRecordButtonMode == .record ? .record : .textSend
            ))
        }
        var didRestoreSendImage = false
        if self.sendButton.image(for: .normal) == nil {
            self.sendButton.setImage(Self.composerActionButtonImage(for: .textSend), for: .normal)
            didRestoreSendImage = true
        }
        if self.sendButton.configuration != nil {
            ModernXabberInputView.removeChrome(from: self.sendButton)
        }
        if didRestoreSendImage {
            self.sendButton.imageView?.contentMode = .scaleAspectFit
        }
    }

    final func refreshComposerChrome() {
        self.restoreComposerActionGlyphs()
        self.refreshDetachedComposerButtonChrome()
        self.restoreScheduledMessagesButtonGlyph()
        self.updateScheduledMessagesButtonVisibility()
        self.setNeedsLayout()
    }
    
    @objc
    final func textViewDidChange(force: Bool = false) {
        if !self.isApplyingComposerMutation {
            self.normalizeTypingAttributesAtCursor()
        }
        if self.textField.isFirstResponder {
            ChatUIResponsivenessGate.shared.activate(reason: .typing)
        }
        let rawText = textField.text ?? ""
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousVisualState = self.currentComposerTypingVisualState()
        
        self.textField.placeholderLabel.isHidden = !rawText.isEmpty
        self.message = trimmedText
        
        let currentContentHeight = self.contentView.bounds.height > 0
            ? self.contentView.bounds.height
            : self.currentComposerContentHeight()
        let nextVisualState = ComposerTypingUpdatePolicy.visualState(
            inputState: self.state,
            rawText: rawText,
            trimmedText: trimmedText,
            shouldHideTimer: self.shouldHideTimer,
            hasScheduledMessages: self.hasScheduledMessagesForCurrentChat
        )
        let measuredTextViewFittingHeight = self.requiredTextViewFittingHeight
        let requiredContentHeight = self.requiredInputTextViewHeight(
            fittingHeight: measuredTextViewFittingHeight
        )
        let decision = ComposerTypingUpdatePolicy.decision(
            force: force,
            requiredContentHeight: requiredContentHeight,
            currentContentHeight: currentContentHeight,
            previousVisualState: previousVisualState,
            nextVisualState: nextVisualState
        )
        if decision.shouldInvalidateIntrinsicContentSize {
            self.measuredTextViewFittingHeightForInvalidation = measuredTextViewFittingHeight
            invalidateIntrinsicContentSize()
            self.measuredTextViewFittingHeightForInvalidation = nil
        }

        if decision.shouldUpdateControls {
            self.applyComposerTypingVisualState(nextVisualState, force: force)
        }
        self.delegate?.onTextDidChange(to: trimmedText.isEmpty ? nil : trimmedText)
        self.updateMentionSuggestions()
    }

    func baseComposerAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: self.textField.font ?? UIFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: UIColor.label
        ]
    }

    func mentionComposerAttributes(for entity: ComposerMentionEntity) -> [NSAttributedString.Key: Any] {
        var attributes = self.baseComposerAttributes()
        attributes[.font] = UIFont.systemFont(ofSize: 14, weight: .semibold)
        attributes[.foregroundColor] = self.accountPalette.tint700
        attributes[.backgroundColor] = self.accountPalette.tint100.withAlphaComponent(0.75)
        attributes[.composerMention] = entity
        attributes[.link] = entity.uri
        return attributes
    }

    func currentPayload() -> ComposerMessagePayload {
        ComposerMentionSerializer.payload(
            from: self.textField.attributedText ?? NSAttributedString(string: "", attributes: self.baseComposerAttributes())
        )
    }

    func setComposerText(_ text: String?) {
        let value = text ?? ""
        let attributed = NSAttributedString(string: value, attributes: self.baseComposerAttributes())
        self.applyComposerAttributedText(attributed, selectedRange: NSRange(location: attributed.length, length: 0))
    }

    func setComposerBody(_ body: String, references: [MessageReferenceStorageItem]) {
        let attributed = ComposerMentionSerializer.attributedText(
            body: body,
            references: references,
            baseAttributes: self.baseComposerAttributes(),
            mentionAttributesProvider: { [weak self] entity in
                self?.mentionComposerAttributes(for: entity) ?? [.composerMention: entity]
            }
        )
        self.applyComposerAttributedText(attributed, selectedRange: NSRange(location: attributed.length, length: 0))
    }

    func clearComposer() {
        self.hideMentionSuggestions()
        self.setComposerText(nil)
    }

    func refreshMentionSuggestions() {
        guard self.currentMentionQuery != nil else { return }
        self.isMentionUsersReloadInFlight = false
        self.updateMentionSuggestions()
    }

    private func applyComposerAttributedText(_ attributedText: NSAttributedString, selectedRange: NSRange? = nil) {
        self.isApplyingComposerMutation = true
        self.textField.attributedText = attributedText
        self.textField.typingAttributes = self.baseComposerAttributes()
        if let selectedRange {
            self.textField.selectedRange = selectedRange
        }
        self.isApplyingComposerMutation = false
        self.textField.placeholderLabel.isHidden = !self.textField.text.isEmpty
        self.updateScheduledMessagesButtonVisibility()
    }

    private func currentComposerTypingVisualState() -> ComposerTypingVisualState {
        ComposerTypingVisualState(
            actionMode: self.currentComposerActionMode,
            timerHidden: self.timerButton.isHidden,
            scheduledMessagesVisible: !self.scheduledMessagesButton.isHidden
        )
    }

    private func applyComposerTypingVisualState(
        _ visualState: ComposerTypingVisualState,
        force: Bool
    ) {
        if self.state == .normal {
            self.timerButton.isHidden = visualState.timerHidden
        }
        self.applyScheduledMessagesButtonVisibility(visualState.scheduledMessagesVisible)
        self.changeComposerActionMode(
            to: visualState.actionMode,
            animated: !force && self.state == .normal
        )
    }

    private func updateScheduledMessagesButtonVisibility() {
        self.restoreScheduledMessagesButtonGlyph()
        let shouldShow = ScheduledMessagesComposerButtonPolicy.shouldShow(
            inputState: self.state,
            body: self.textField.text ?? "",
            hasScheduledMessages: self.hasScheduledMessagesForCurrentChat
        )
        self.applyScheduledMessagesButtonVisibility(shouldShow)
    }

    private func applyScheduledMessagesButtonVisibility(_ shouldShow: Bool) {
        let didChange = self.scheduledMessagesButton.isHidden == shouldShow
            || self.scheduledMessagesButton.isEnabled != shouldShow
            || self.scheduledMessagesButton.isUserInteractionEnabled != shouldShow
            || self.scheduledMessagesButton.accessibilityElementsHidden == shouldShow
        guard didChange else {
            return
        }

        self.scheduledMessagesButton.isHidden = !shouldShow
        self.scheduledMessagesButton.isEnabled = shouldShow
        self.scheduledMessagesButton.isUserInteractionEnabled = shouldShow
        self.scheduledMessagesButton.accessibilityElementsHidden = !shouldShow
        self.updateTextFieldTrailingConstraint()
        self.setNeedsLayout()
    }

    private func normalizeTypingAttributesAtCursor() {
        guard !self.isNormalizingTypingAttributes else { return }
        let expectedAttributes = self.baseComposerAttributes()
        let currentAttributes = self.textField.typingAttributes
        guard !NSDictionary(dictionary: currentAttributes).isEqual(to: expectedAttributes) else {
            return
        }

        self.isNormalizingTypingAttributes = true
        self.textField.typingAttributes = expectedAttributes
        self.isNormalizingTypingAttributes = false
    }

    private func layoutMentionPanel() {
        guard !self.mentionPanel.isHidden else { return }
        self.attachMentionPanelIfNeeded()
        guard let superview = self.superview else { return }
        let maxHeight = min(260, UIScreen.main.bounds.height * 0.34)
        let height = self.mentionPanel.preferredHeight(maxHeight: maxHeight)
        let width = max(220, self.bounds.width - 84)
        let localFrame = CGRect(
            x: 40,
            y: -(height + 8),
            width: width,
            height: height
        )
        self.mentionPanel.frame = self.convert(localFrame, to: superview)
    }

    private func hideMentionSuggestions() {
        self.currentMentionQuery = nil
        self.isMentionUsersReloadInFlight = false
        self.mentionPanel.isHidden = true
        self.mentionPanel.removeFromSuperview()
    }

    private func updateMentionSuggestions() {
        guard self.state == .normal,
              self.mentionConversationType == .group,
              self.textField.markedTextRange == nil,
              let attributedText = self.textField.attributedText else {
            self.hideMentionSuggestions()
            return
        }

        guard let query = ComposerMentionQueryDetector.activeQuery(
            in: attributedText,
            selectedRange: self.textField.selectedRange
        ) else {
            self.hideMentionSuggestions()
            return
        }

        self.currentMentionQuery = query
        let candidates = self.mentionCandidatesProvider?(query.query) ?? []
        let membersCount = self.mentionMembersCountProvider?() ?? candidates.count
        let shouldReload = membersCount == 0 && !self.isMentionUsersReloadInFlight
        if shouldReload {
            self.isMentionUsersReloadInFlight = true
            self.mentionUsersReloadHandler?()
        }

        self.mentionPanel.update(items: candidates, isLoading: shouldReload)
        self.layoutMentionPanel()
    }

    private func resolvedMentionQuery(in attributedText: NSAttributedString) -> ComposerMentionQueryState? {
        if let currentMentionQuery {
            return currentMentionQuery
        }

        return ComposerMentionQueryDetector.activeQuery(
            in: attributedText,
            selectedRange: self.textField.selectedRange
        )
    }

    private func insertMentionCandidate(_ candidate: ComposerMentionCandidate) {
        guard let attributedText = self.textField.attributedText,
              let mentionQuery = self.resolvedMentionQuery(in: attributedText) else {
            return
        }
        let entity = candidate.mentionEntity
        let result = ComposerMentionEditor.insertMention(
            in: attributedText,
            replacementRange: mentionQuery.replacementRange,
            entity: entity,
            baseAttributes: self.baseComposerAttributes(),
            mentionAttributes: self.mentionComposerAttributes(for: entity)
        )
        self.applyComposerAttributedText(result.attributedText, selectedRange: result.selectedRange)
        self.hideMentionSuggestions()
        self.textField.becomeFirstResponder()
    }
    
    enum ComposerActionMode: Equatable {
        case record
        case textSend
    }

    private enum VoiceRecordButtonMode: Equatable {
        case record
        case sendVoice
    }

    private static let recordComposerActionButtonImage = makeComposerActionButtonImage(for: .record)
    private static let sendComposerActionButtonImage = makeComposerActionButtonImage(for: .textSend)

    static func composerActionButtonImage(for mode: ComposerActionMode) -> UIImage? {
        switch mode {
        case .record:
            return self.recordComposerActionButtonImage
        case .textSend:
            return self.sendComposerActionButtonImage
        }
    }

    private static func makeComposerActionButtonImage(for mode: ComposerActionMode) -> UIImage? {
        guard let image = self.composerActionButtonSymbolImage(for: mode)
                ?? self.composerActionButtonAssetFallbackImage(for: mode) else {
            return nil
        }
        return self.normalizedComposerActionImage(image)
            .withRenderingMode(.alwaysTemplate)
    }

    private static func composerAttachmentButtonImage() -> UIImage? {
        guard let image = imageLiteral("paperclip", dimension: Self.composerActionIconSize) else {
            return nil
        }
        return self.normalizedComposerActionImage(image)
            .withRenderingMode(.alwaysTemplate)
    }

    private static func composerActionButtonSymbolImage(for mode: ComposerActionMode) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: Self.composerActionIconSize, weight: .regular)
        switch mode {
            case .record:
                return UIImage(systemName: "mic.fill", withConfiguration: configuration)
            case .textSend:
                return UIImage(systemName: "paperplane.fill", withConfiguration: configuration)
        }
    }

    private static func composerActionButtonAssetFallbackImage(for mode: ComposerActionMode) -> UIImage? {
        switch mode {
            case .record:
                return imageLiteral("mic.fill", dimension: Self.composerActionIconSize)
            case .textSend:
                return imageLiteral("xabber.paperplane.fill", dimension: Self.composerActionIconSize)
        }
    }

    private static func normalizedComposerActionImage(_ image: UIImage) -> UIImage {
        let targetSize = CGSize(width: Self.composerActionIconSize, height: Self.composerActionIconSize)
        guard image.size.width > 0,
              image.size.height > 0 else {
            return image
        }

        let scale = min(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = CGRect(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        return renderer.image { _ in
            image.withRenderingMode(.alwaysOriginal).draw(in: drawRect)
        }
    }

    private func applyRecordButtonIcon(for mode: VoiceRecordButtonMode, animated: Bool) {
        let actionMode: ComposerActionMode = mode == .record ? .record : .textSend
        let image = Self.composerActionButtonImage(for: actionMode)
        if animated,
           #available(iOS 17.0, *),
           let image {
            if self.animateRecordButtonIcon(
                to: image,
                for: mode
            ) {
                return
            }
        }

        self.setRecordButtonImage(image)
    }

    @available(iOS 17.0, *)
    private func animateRecordButtonIcon(
        to image: UIImage,
        for mode: VoiceRecordButtonMode
    ) -> Bool {
        self.recordButton.layoutIfNeeded()
        guard let imageView = self.recordButton.imageView else {
            return false
        }

        self.setRecordButtonImage(image)
        imageView.tintColor = self.recordButton.tintColor
        imageView.setSymbolImage(
            image,
            contentTransition: .replace,
            options: .nonRepeating
        ) { [weak self] context in
            guard context.isFinished,
                  let self,
                  self.voiceRecordButtonMode == mode else {
                return
            }
            self.setRecordButtonImage(image)
        }
        return true
    }

    private func setRecordButtonImage(_ image: UIImage?) {
        self.recordButton.setImage(image, for: .normal)
        guard var configuration = self.recordButton.configuration else { return }
        configuration.image = image
        configuration.baseForegroundColor = self.recordButton.tintColor
        self.recordButton.configuration = configuration
    }
    
    public var isSendButtonEnabled: Bool = false

    final func changeComposerActionMode(to mode: ComposerActionMode, animated: Bool = false) {
        let previousMode = self.currentComposerActionMode
        self.currentComposerActionMode = mode
        self.updateComposerActionColors()

        guard self.state == .normal else {
            self.updateComposerControlLayout()
            return
        }

        self.composerActionTransitionGeneration += 1
        let generation = self.composerActionTransitionGeneration
        let incoming = mode == .textSend ? self.sendButton : self.recordButton
        let outgoing = mode == .textSend ? self.recordButton : self.sendButton

        guard previousMode != mode, animated else {
            outgoing.isHidden = true
            incoming.isHidden = false
            [incoming, outgoing].forEach {
                $0.layer.removeAllAnimations()
                $0.alpha = 1
                $0.transform = .identity
            }
            self.updateComposerControlLayout()
            self.setNeedsLayout()
            return
        }

        self.layoutIfNeeded()
        incoming.layer.removeAllAnimations()
        outgoing.layer.removeAllAnimations()
        incoming.isHidden = false
        outgoing.isHidden = false
        incoming.alpha = 0
        incoming.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
        outgoing.alpha = 1
        outgoing.transform = .identity
        self.updateComposerControlLayout()

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
            animations: {
                incoming.alpha = 1
                incoming.transform = .identity
                outgoing.alpha = 0
                outgoing.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
                self.layoutIfNeeded()
            },
            completion: { [weak self] _ in
                guard let self,
                      self.composerActionTransitionGeneration == generation else {
                    return
                }
                outgoing.isHidden = true
                incoming.isHidden = false
                [incoming, outgoing].forEach {
                    $0.alpha = 1
                    $0.transform = .identity
                }
                self.updateComposerControlLayout()
            }
        )
    }

    private func changeVoiceRecordButtonMode(to mode: VoiceRecordButtonMode, animated: Bool) {
        let previousMode = self.voiceRecordButtonMode
        self.voiceRecordButtonMode = mode
        self.recordButton.accessibilityLabel = (mode == .record
            ? "Record voice message"
            : "Send voice message").localizeString(
                id: mode == .record
                    ? "chat_composer_record_voice_message_accessibility"
                    : "chat_composer_send_voice_message_accessibility",
                arguments: []
            )
        self.recordButton.accessibilityHint = mode == .record
            ? "Hold to record, slide left to cancel, or slide up to lock".localizeString(
                id: "chat_composer_record_voice_message_hint",
                arguments: []
            )
            : nil
        self.updateComposerActionColors()
        self.applyRecordButtonIcon(for: mode, animated: animated && previousMode != mode)
    }

    private func updateComposerActionColors() {
        self.attachButton.isEnabled = true
        self.recordButton.isEnabled = self.isSendButtonEnabled
        self.sendButton.isEnabled = self.isSendButtonEnabled
        self.sendButton.tintColor = self.isSendButtonEnabled ? self.accountPalette.tint600 : .secondaryLabel

        if !self.recordButton.pulseView.isHidden {
            self.recordButton.tintColor = .white
        } else if self.voiceRecordButtonMode == .sendVoice {
            self.recordButton.tintColor = self.isSendButtonEnabled ? self.accountPalette.tint600 : .secondaryLabel
        } else {
            self.recordButton.tintColor = .secondaryLabel
        }

        if self.sendButton.image(for: .normal) == nil {
            self.sendButton.setImage(Self.composerActionButtonImage(for: .textSend), for: .normal)
        }
        self.sendButton.imageView?.contentMode = .scaleAspectFit
        self.refreshDetachedComposerButtonChrome()
    }
    
    final public func updateComposerActionReadiness() {
        self.updateComposerActionColors()
    }
    
    
    /// Invalidates the view’s intrinsic content size
    final override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        cachedIntrinsicContentSize = calculateIntrinsicContentSize()
        if previousIntrinsicContentSize?.height != cachedIntrinsicContentSize.height {
            previousIntrinsicContentSize = cachedIntrinsicContentSize
        }
        
        let contentHeight = self.currentComposerContentHeight()
        self.barHeight = contentHeight + LiquidGlassMetrics.verticalReserve
        let inputHeight = self.resolvedInputHeight(
            keyboardHeight: self.keyboardHeight
        )
        
        //UIView.animate(withDuration: 0.16, delay: 0.0, options: [.curveEaseIn]) {
        UIView.performWithoutAnimation {
            self.delegate?.onHeightChanged(to: inputHeight, bar: 0)
            self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight)
        }
        self.setNeedsLayout()
        
    }
    
    // MARK: - Layout Helper Methods
    
    /// Calculates the correct intrinsicContentSize of the MessageInputBar. This takes into account the various padding edge
    /// insets, InputTextView's height and top/bottom InputStackView's heights.
    ///
    /// - Returns: The required intrinsicContentSize
    final func calculateIntrinsicContentSize() -> CGSize {
        if self.isSelectionPanelShowed {
            return CGSize(width: UIView.noIntrinsicMetric, height: ModernXabberInputView.minimumComposerHeight)
        }

        var inputTextViewHeight = self.measuredTextViewFittingHeightForInvalidation
            ?? self.requiredTextViewFittingHeight
        if inputTextViewHeight >= maxTextViewHeight {
            if !isOverMaxTextViewHeight {
//                textViewHeightAnchor?.isActive = true
                textField.isScrollEnabled = true
                isOverMaxTextViewHeight = true
            }
            inputTextViewHeight = maxTextViewHeight
        } else {
            if isOverMaxTextViewHeight {
//                textViewHeightAnchor?.isActive = false //|| shouldForceTextViewMaxHeight
                textField.isScrollEnabled = false
                isOverMaxTextViewHeight = false
            }
        }
        
        let requiredHeight = self.normalizedComposerContentHeight(
            for: inputTextViewHeight + self.composerTextVerticalPadding
        )
//        print("requiredHeight", requiredHeight)
//        self.delegate?.heightDidChange(self, to: requiredHeight)
        return CGSize(width: UIView.noIntrinsicMetric, height: requiredHeight)
    }
    
    @objc
    private func onAttachButtonTouchDown(_ sender: UIButton) {
        NSLog(
            "ATTACHMENT_TAP event=touch_down enabled=%@ hidden=%@ alpha=%.2f frame=%@",
            sender.isEnabled.description,
            sender.isHidden.description,
            sender.alpha,
            NSCoder.string(for: sender.frame)
        )
    }

    @objc
    private func onAttachButtonTouchUp(_ sender: UIButton) {
        NSLog(
            "ATTACHMENT_TAP event=touch_up_inside delegate=%@ window=%@",
            (self.delegate != nil).description,
            (sender.window != nil).description
        )
        self.delegate?.attachmentButtonTouchUp()
    }
    
    @objc
    private func onTimerButtonTouchUp(_ sender: UIButton) {
        self.delegate?.onAfterburnButtonTouchUp()
    }
        
    @objc
    private func onRecordButtonTouchUp(_ sender: UIButton) {
        if case .lockedRecording = self.voiceRecordingInteraction.state {
            let actions = self.voiceRecordingInteraction.sendLockedRecording(at: Date().timeIntervalSince1970)
            if !actions.isEmpty {
                self.applyVoiceRecordingActions(actions)
                return
            }
        }
        if self.state == .recordAndPlay {
            let actions = self.voiceRecordingInteraction.sendPreview()
            if !actions.isEmpty {
                self.applyVoiceRecordingActions(actions)
                return
            }
        }
    }

    @objc
    private func onTextSendButtonTouchUp(_ sender: UIButton) {
        guard self.state == .normal,
              self.currentComposerActionMode == .textSend,
              self.isSendButtonEnabled else {
            return
        }
        self.hideMentionSuggestions()
        self.delegate?.sendButtonTouchUp(with: self.textField.text)
    }

    @objc
    private func onScheduledMessagesButtonTouchUp(_ sender: UIButton) {
        guard !sender.isHidden, sender.isEnabled else { return }
        self.delegate?.scheduledMessagesButtonTouchUp()
    }

    @objc
    private func onRecordLockButtonTouchUp(_ sender: UIButton) {
        guard self.recordLockButtonAllowsStop else { return }
        self.stopLockedAudioRecording()
    }

    func updateRecordingMeteringLevel(_ rawLevel: Float, animated: Bool = true) {
        let finiteRawLevel = rawLevel.isFinite ? rawLevel : 0
        let clampedLevel = min(max(CGFloat(finiteRawLevel), 0), 1)
        let smoothing = clampedLevel >= self.smoothedRecordingMeteringLevel
            ? RecordingGlowMetrics.riseSmoothing
            : RecordingGlowMetrics.fallSmoothing
        self.smoothedRecordingMeteringLevel += (clampedLevel - self.smoothedRecordingMeteringLevel) * smoothing
        self.recordButton.updatePulseGlow(
            level: self.smoothedRecordingMeteringLevel,
            color: self.accountPalette.tint500,
            animated: animated
        )
    }

    func showRecordingLockOverlay(isLocked: Bool, allowsStop: Bool, animated: Bool = true) {
        self.recordLockButtonAllowsStop = allowsStop
        self.recordLockButton.isHidden = false
        self.recordLockButton.alpha = 1
        self.recordLockButton.tintColor = isLocked ? self.accountPalette.tint600 : .secondaryLabel
        self.updateRecordingLockAccessibility(isLocked: isLocked, allowsStop: allowsStop)

        let configuration = UIImage.SymbolConfiguration(pointSize: NativeGlassBarStyle.iconSize, weight: .regular)
        let image = UIImage(
            systemName: isLocked ? "lock.fill" : "lock.open.fill",
            withConfiguration: configuration
        )
        let updateImage = {
            self.recordLockButton.setImage(image, for: .normal)
            ModernXabberInputView.applyDetachedGlassButtonStyle(to: self.recordLockButton)
        }

        guard animated else {
            updateImage()
            self.recordLockButtonIconScale = 1
            self.updateRecordLockButtonTransform()
            return
        }

        UIView.transition(
            with: self.recordLockButton,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: updateImage
        )
        self.recordLockButtonIconScale = 0.92
        self.updateRecordLockButtonTransform()
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.35,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                self.recordLockButtonIconScale = 1
                self.updateRecordLockButtonTransform()
            }
        )
    }

    func hideRecordingLockOverlay(animated: Bool = false) {
        self.recordLockButtonAllowsStop = false
        self.recordLockButton.layer.removeAllAnimations()
        let updates = {
            self.recordLockButton.alpha = 0
        }
        let completion: (Bool) -> Void = { _ in
            self.recordLockButton.isHidden = true
            self.recordLockButton.alpha = 1
            self.recordLockButtonVisualTranslation = .zero
            self.recordLockButtonIconScale = 1
            self.updateRecordLockButtonTransform()
            self.updateRecordingLockAccessibility(isLocked: false, allowsStop: false)
        }

        guard animated else {
            completion(true)
            return
        }

        UIView.animate(
            withDuration: 0.14,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: updates,
            completion: completion
        )
    }

    func resetRecordingOverlayVisuals() {
        self.smoothedRecordingMeteringLevel = 0
        self.recordButton.hidePulse()
        self.hideRecordingLockOverlay(animated: false)
        self.setRecordButtonDetachedChromeHidden(false)
        self.changeVoiceRecordButtonMode(to: .record, animated: false)
    }

    private func updateRecordingLockAccessibility(isLocked: Bool, allowsStop: Bool) {
        if isLocked {
            self.recordLockButton.accessibilityLabel = "Recording locked".localizeString(
                id: "chat_composer_recording_locked_accessibility",
                arguments: []
            )
            self.recordLockButton.accessibilityValue = "Locked".localizeString(
                id: "chat_composer_recording_locked_value",
                arguments: []
            )
            self.recordLockButton.accessibilityHint = allowsStop
                ? "Double-tap to stop recording".localizeString(
                    id: "chat_composer_recording_stop_hint",
                    arguments: []
                )
                : nil
        } else {
            self.recordLockButton.accessibilityLabel = "Lock recording".localizeString(
                id: "chat_composer_lock_recording_accessibility",
                arguments: []
            )
            self.recordLockButton.accessibilityValue = "Unlocked".localizeString(
                id: "chat_composer_recording_unlocked_value",
                arguments: []
            )
            self.recordLockButton.accessibilityHint = "Slide up to lock recording".localizeString(
                id: "chat_composer_recording_lock_hint",
                arguments: []
            )
        }
    }

    private func setRecordLockButtonVisualTranslation(_ translation: CGPoint) {
        guard self.recordLockButtonVisualTranslation != translation else { return }
        self.recordLockButtonVisualTranslation = translation
        self.updateRecordLockButtonTransform()
    }

    private func updateRecordLockButtonTransform() {
        self.recordLockButton.transform = CGAffineTransform(
            translationX: self.recordLockButtonVisualTranslation.x,
            y: self.recordLockButtonVisualTranslation.y
        ).scaledBy(
            x: self.recordLockButtonIconScale,
            y: self.recordLockButtonIconScale
        )
    }

    func resetRecordingButtonPositionAndVisibility(animated: Bool) {
        self.resetRecordingButtonPositionAndVisibility(animated: animated, enforceVisibility: true)
    }

    private func resetRecordingButtonPositionAndVisibility(animated: Bool, enforceVisibility: Bool) {
        let updates = {
            self.recordButton.transform = .identity
            self.recordButton.layer.removeAllAnimations()
            self.startPositionRecordButton = self.recordButton.center
            self.recordButton.setRecordingVisualTranslation(.zero, animated: false)
            self.recordLockButtonIconScale = 1
            self.setRecordLockButtonVisualTranslation(.zero)
            self.updateRecordLockButtonTransform()
            self.setRecordButtonDetachedChromeHidden(
                self.state == .record && !self.recordButton.pulseView.isHidden
            )
            if enforceVisibility {
                self.recordButton.isHidden = !self.shouldShowRecordButton(in: self.state)
            }
            self.recordButton.updatePulseOverlayPosition()
        }

        guard animated else {
            UIView.performWithoutAnimation(updates)
            return
        }

        UIView.animate(
            withDuration: 0.3,
            delay: 0.0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.6,
            options: [.curveEaseOut],
            animations: updates
        ) { _ in
            updates()
        }
    }

    private func shouldShowRecordButton(in state: InputBarState) -> Bool {
        switch state {
        case .normal:
            return self.currentComposerActionMode == .record
        case .record, .recordAndPlay:
            return true
        case .identityVerification, .updateSignature, .checkDevices, .checkOwnDevices, .checkContactDevices, .skeleton, .selection, .search:
            return false
        }
    }

    private func returnRecordButtonToInitialPosition() {
        self.resetRecordingButtonPositionAndVisibility(animated: true)
    }
    
    func cancelRecord() {
        _ = self.voiceRecordingInteraction.reset()
        self.resetVoiceRecordingUI()
    }
    
    func resetStateAfterRecord() {
        self.cancelRecord()
    }
        
    var startPositionRecordButton: CGPoint!

    @objc
    private func voiceRecordingLongPressGesture(_ sender: UILongPressGestureRecognizer) {
        let timestamp = Date().timeIntervalSince1970
        switch sender.state {
        case .began:
            guard self.currentComposerActionMode == .record,
                  self.voiceRecordButtonMode == .record,
                  self.state == .normal,
                  self.isSendButtonEnabled else {
                return
            }
            self.voiceRecordingGestureStartLocation = sender.location(in: self)
            self.applyVoiceRecordingActions(self.voiceRecordingInteraction.beginPress(at: timestamp))
        case .changed:
            guard let startLocation = self.voiceRecordingGestureStartLocation else { return }
            let location = sender.location(in: self)
            let translation = CGPoint(x: location.x - startLocation.x, y: location.y - startLocation.y)
            self.applyVoiceRecordingActions(self.voiceRecordingInteraction.dragChanged(to: translation))
        case .ended:
            self.applyVoiceRecordingActions(self.voiceRecordingInteraction.endPress(at: timestamp))
            self.voiceRecordingGestureStartLocation = nil
            self.returnRecordButtonToInitialPosition()
        case .cancelled, .failed:
            self.applyVoiceRecordingActions(self.voiceRecordingInteraction.cancelActive())
            self.voiceRecordingGestureStartLocation = nil
            self.returnRecordButtonToInitialPosition()
        default:
            break
        }
    }

    @objc
    private func textSendMenuLongPressGesture(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began,
              self.shouldBeginTextSendMenuGesture() else {
            return
        }
        self.hideMentionSuggestions()
        self.delegate?.sendButtonLongPressMenuRequested(
            sourceView: self.sendOptionsMenuSourceView,
            payload: self.currentPayload()
        )
    }

    private func shouldBeginTextSendMenuGesture() -> Bool {
        ChatSendOptionsMenuPolicy.shouldPresentTextSendMenu(
            actionMode: self.currentComposerActionMode,
            inputState: self.state,
            isSendButtonEnabled: self.isSendButtonEnabled,
            body: self.currentPayload().body
        )
    }

    @objc
    private func lockedVoiceRecordingCancelPanGesture(_ sender: UIPanGestureRecognizer) {
        let translation = sender.translation(in: self)
        switch sender.state {
        case .began, .changed:
            self.applyLockedVoiceRecordingCancelDrag(translation, finished: false)
        case .ended, .cancelled, .failed:
            self.applyLockedVoiceRecordingCancelDrag(translation, finished: true)
        default:
            break
        }
    }

    func applyLockedVoiceRecordingCancelDrag(_ translation: CGPoint, finished: Bool) {
        guard case .lockedRecording = self.voiceRecordingInteraction.state else { return }
        self.applyVoiceRecordingActions(self.voiceRecordingInteraction.dragChanged(to: translation))
        if finished, case .lockedRecording = self.voiceRecordingInteraction.state {
            self.returnRecordButtonToInitialPosition()
        }
    }

    private func cancelActiveVoiceRecordingFromControl() {
        self.applyVoiceRecordingActions(self.voiceRecordingInteraction.cancelActive())
    }

    func stopLockedAudioRecording() {
        self.applyVoiceRecordingActions(
            self.voiceRecordingInteraction.stopLockedRecording(at: Date().timeIntervalSince1970)
        )
    }

    private func deleteVoiceRecordingPreview() {
        self.applyVoiceRecordingActions(self.voiceRecordingInteraction.deletePreview())
    }

    private func playVoiceRecordingPreview() {
        guard case .preview(let sessionID) = self.voiceRecordingInteraction.state else { return }
        self.delegate?.recordAndPlayPanelPlayButtonTouchUp(sessionID: sessionID)
    }

    func audioRecordingDidStart(sessionID: UUID) {
        self.applyVoiceRecordingActions(self.voiceRecordingInteraction.recorderStarted(sessionID: sessionID))
    }

    func audioRecordingDidFail(sessionID: UUID?) {
        self.applyVoiceRecordingActions(self.voiceRecordingInteraction.recorderFailed(sessionID: sessionID))
    }

    func audioRecordingDidCancel(sessionID: UUID) {
        self.applyVoiceRecordingActions(self.voiceRecordingInteraction.complete(sessionID: sessionID))
    }

    func audioRecordingDidSend(sessionID: UUID) {
        self.applyVoiceRecordingActions(self.voiceRecordingInteraction.complete(sessionID: sessionID))
    }

    func audioRecordingPreviewReady(sessionID: UUID) {
        guard case .preview(let currentSessionID) = self.voiceRecordingInteraction.state,
              currentSessionID == sessionID else {
            return
        }
        self.showVoiceRecordingPreviewUI()
    }

    func applyVoiceRecordingActions(_ actions: [VoiceRecordingInteractionStateMachine.Action]) {
        actions.forEach { action in
            switch action {
            case .requestStartRecording(let sessionID):
                self.beginVoiceRecordingUI()
                self.delegate?.onAudioMessageStartRecord(sessionID: sessionID)
            case .showRecording:
                self.recordPanel.resetAndStart()
            case .updateDrag(let translation):
                self.updateVoiceRecordingDragUI(translation)
            case .lockRecording:
                self.lockVoiceRecordingUI()
            case .cancelRecording(let sessionID):
                self.resetVoiceRecordingUI()
                self.delegate?.onAudioMessageDidCancel(sessionID: sessionID)
                _ = self.voiceRecordingInteraction.reset()
            case .finishRecording(let sessionID, let intent):
                self.finishVoiceRecordingUI()
                self.delegate?.onAudioMessageDidFinish(sessionID: sessionID, intent: intent)
            case .deletePreview(let sessionID):
                self.delegate?.onAudioMessagePreviewDelete(sessionID: sessionID)
            case .sendPreview(let sessionID):
                self.delegate?.onAudioMessagePreviewSend(sessionID: sessionID)
            case .resetUI:
                self.resetVoiceRecordingUI()
            case .fail:
                self.resetVoiceRecordingUI()
            }
        }
    }

    private func beginVoiceRecordingUI() {
        FeedbackManager.shared.generate(feedback: .success)
        self.hideMentionSuggestions()
        self.changeVoiceRecordButtonMode(to: .record, animated: false)
        self.changeState(to: .record)
        self.recordPanel.resetElements()
        self.setRecordButtonDetachedChromeHidden(true)
        self.smoothedRecordingMeteringLevel = 0
        self.recordButton.setIndicatorColors(
            core: self.accountPalette.tint600,
            halo: self.accountPalette.tint500
        )
        self.recordButton.showPulse()
        self.updateComposerActionColors()
        self.updateRecordingMeteringLevel(0, animated: false)
        self.showRecordingLockOverlay(isLocked: false, allowsStop: false, animated: true)
    }

    private func finishVoiceRecordingUI() {
        self.recordPanel.done()
        self.recordPanel.resetElements()
        self.resetRecordingOverlayVisuals()
        self.returnRecordButtonToInitialPosition()
        self.changeState(to: .normal)
        self.textViewDidChange(force: true)
    }

    private func resetVoiceRecordingUI() {
        self.voiceRecordingGestureStartLocation = nil
        self.recordPanel.done()
        self.recordPanel.resetElements()
        self.recordAndPlayPanel.resetElements()
        self.resetRecordingOverlayVisuals()
        self.returnRecordButtonToInitialPosition()
        self.changeState(to: .normal)
        self.textViewDidChange(force: true)
    }

    private func showVoiceRecordingPreviewUI() {
        self.recordPanel.done()
        self.recordPanel.resetElements()
        self.resetRecordingOverlayVisuals()
        self.returnRecordButtonToInitialPosition()
        self.changeState(to: .recordAndPlay)
        self.isSendButtonEnabled = true
        self.changeVoiceRecordButtonMode(to: .sendVoice, animated: true)
    }

    func updateVoiceRecordingDragUI(_ translation: CGPoint) {
        let visualTranslation = self.clampedRecordingButtonTranslation(
            RecordingDragVisualPolicy.clamped(translation)
        )
        self.recordPanel.slideToCancel(diffX: visualTranslation.x)
        self.recordPanel.slideToLock(point: visualTranslation)
        self.recordButton.setRecordingVisualTranslation(visualTranslation)
        self.setRecordLockButtonVisualTranslation(visualTranslation)
        self.setRecordButtonDetachedChromeHidden(true)
    }

    private func clampedRecordingButtonTranslation(_ translation: CGPoint) -> CGPoint {
        guard let hostView = self.superview else { return translation }

        let currentRecordTransform = self.recordButton.transform
        let currentLockTransform = self.recordLockButton.transform
        self.recordButton.transform = .identity
        self.recordLockButton.transform = .identity
        let recordBaseFrame = self.recordButton.convert(self.recordButton.bounds, to: hostView)
        let lockBaseFrame = self.recordLockButton.isHidden
            ? .null
            : self.recordLockButton.convert(self.recordLockButton.bounds, to: hostView)
        self.recordButton.transform = currentRecordTransform
        self.recordLockButton.transform = currentLockTransform
        let baseFrame = lockBaseFrame.isNull ? recordBaseFrame : recordBaseFrame.union(lockBaseFrame)
        guard !baseFrame.isNull, !baseFrame.isEmpty else { return translation }

        let safeBounds = hostView.bounds.inset(by: hostView.safeAreaInsets)
        guard !safeBounds.isNull, !safeBounds.isEmpty else { return translation }

        var adjusted = translation
        var proposedFrame = baseFrame.offsetBy(dx: adjusted.x, dy: adjusted.y)

        if proposedFrame.minX < safeBounds.minX {
            adjusted.x += safeBounds.minX - proposedFrame.minX
            proposedFrame = baseFrame.offsetBy(dx: adjusted.x, dy: adjusted.y)
        }
        if proposedFrame.maxX > safeBounds.maxX {
            adjusted.x -= proposedFrame.maxX - safeBounds.maxX
            proposedFrame = baseFrame.offsetBy(dx: adjusted.x, dy: adjusted.y)
        }
        if proposedFrame.minY < safeBounds.minY {
            adjusted.y += safeBounds.minY - proposedFrame.minY
            proposedFrame = baseFrame.offsetBy(dx: adjusted.x, dy: adjusted.y)
        }
        if proposedFrame.maxY > safeBounds.maxY {
            adjusted.y -= proposedFrame.maxY - safeBounds.maxY
        }

        return adjusted
    }

    func lockVoiceRecordingUI() {
        self.recordPanel.lock()
        self.recordPanel.slideToCancelButton.isHidden = true
        self.recordPanel.cancelButton.isHidden = false
        self.recordPanel.changeIndicatorToStop()
        self.showRecordingLockOverlay(isLocked: true, allowsStop: true, animated: true)
        self.changeVoiceRecordButtonMode(to: .sendVoice, animated: true)
        self.setRecordButtonDetachedChromeHidden(true)
        self.updateComposerActionColors()
    }
    
    @objc
    private func onStateButtonTouchUp(_ sender: UIButton) {
        switch state {
            case .updateSignature:
                self.delegate?.onUpdateSignature()
            case .checkDevices, .checkOwnDevices:
                self.delegate?.onCheckDevices()
            case .checkContactDevices:
                self.delegate?.onCheckContactDevices()
            case .identityVerification:
                self.delegate?.onIdentityVerification()
            default: break
        }
    }
    
}

extension ModernXabberInputView: UITextViewDelegate, InputTextViewKeyHandler {
    func textViewDidChangeSelection(_ textView: UITextView) {
        if !self.isApplyingComposerMutation {
            self.normalizeTypingAttributesAtCursor()
        }
        self.updateMentionSuggestions()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        self.hideMentionSuggestions()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n", !self.mentionPanel.isHidden {
            if self.mentionPanel.selectHighlightedItem() != nil {
                return false
            }
        }

        guard let attributedText = textView.attributedText else {
            return true
        }

        if let mutation = ComposerMentionEditor.mutationForEditing(
            attributedText: attributedText,
            range: range,
            replacementText: text,
            baseAttributes: self.baseComposerAttributes()
        ) {
            self.applyComposerAttributedText(mutation.attributedText, selectedRange: mutation.selectedRange)
            return false
        }

        return true
    }

    func inputTextView(_ textView: InputTextView, shouldHandle key: UIKey) -> Bool {
        guard !self.mentionPanel.isHidden else { return false }
        switch key.keyCode {
        case .keyboardUpArrow:
            self.mentionPanel.moveSelection(offset: -1)
            return true
        case .keyboardDownArrow:
            self.mentionPanel.moveSelection(offset: 1)
            return true
        case .keyboardEscape:
            self.hideMentionSuggestions()
            return true
        default:
            return false
        }
    }
}

extension ModernXabberInputView: UIGestureRecognizerDelegate {
    
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === self.voiceRecordingGesture {
            return self.currentComposerActionMode == .record
                && self.voiceRecordButtonMode == .record
                && self.state == .normal
                && self.isSendButtonEnabled
        }
        if gestureRecognizer === self.textSendMenuGesture {
            return self.shouldBeginTextSendMenuGesture()
        }
        if gestureRecognizer === self.lockedVoiceRecordingCancelGesture {
            guard case .lockedRecording = self.voiceRecordingInteraction.state else {
                return false
            }
            return true
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }
}

extension ModernXabberInputView: MulticastAVAudioPlayerDelegate {
    func staticMulticastId() -> String {
        return "xabber_input_view_smid"
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        
    }
    
    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        
    }
    
    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
        
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("finish")
        self.recordAndPlayPanel.waveform.stop()
        self.recordAndPlayPanel.playButton.setImage(imageLiteral("play.fill"), for: .normal)
        self.delegate?.didStopPlayingAudio()
        
    }
}

extension NSAttributedString.Key {
    static let composerMention = NSAttributedString.Key("xabber.composer.mention")
}

final class ComposerMentionEntity: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool = true

    let memberId: String
    let nickname: String
    let uri: String
    let node: String?
    let jid: String?

    init(memberId: String, nickname: String, uri: String, node: String?, jid: String?) {
        self.memberId = memberId
        self.nickname = nickname
        self.uri = uri
        self.node = node
        self.jid = jid
        super.init()
    }

    required init?(coder: NSCoder) {
        guard let memberId = coder.decodeObject(of: NSString.self, forKey: "memberId") as String?,
              let nickname = coder.decodeObject(of: NSString.self, forKey: "nickname") as String?,
              let uri = coder.decodeObject(of: NSString.self, forKey: "uri") as String? else {
            return nil
        }
        self.memberId = memberId
        self.nickname = nickname
        self.uri = uri
        self.node = coder.decodeObject(of: NSString.self, forKey: "node") as String?
        self.jid = coder.decodeObject(of: NSString.self, forKey: "jid") as String?
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(self.memberId, forKey: "memberId")
        coder.encode(self.nickname, forKey: "nickname")
        coder.encode(self.uri, forKey: "uri")
        coder.encode(self.node, forKey: "node")
        coder.encode(self.jid, forKey: "jid")
    }
}

struct ComposerMentionCandidate: Equatable {
    let memberId: String
    let nickname: String
    let uri: String
    let node: String?
    let jid: String?
    let secondaryText: String

    var avatarInitials: String {
        let source = nickname.isEmpty ? (jid ?? memberId) : nickname
        let tokens = source
            .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
            .prefix(2)
            .compactMap { $0.first }
        let value = String(tokens)
        return value.isEmpty ? "@" : value.uppercased()
    }

    var mentionEntity: ComposerMentionEntity {
        ComposerMentionEntity(
            memberId: memberId,
            nickname: nickname,
            uri: uri,
            node: node,
            jid: jid
        )
    }
}

struct ComposerMessagePayload {
    let body: String
    let references: [MessageReferenceStorageItem]
}

struct ComposerMentionQueryState: Equatable {
    let triggerRange: NSRange
    let replacementRange: NSRange
    let query: String
}

struct ComposerTextMutation {
    let attributedText: NSAttributedString
    let selectedRange: NSRange
}

enum ComposerMentionQueryDetector {
    static func activeQuery(in attributedText: NSAttributedString, selectedRange: NSRange) -> ComposerMentionQueryState? {
        guard selectedRange.length == 0 else { return nil }
        let text = attributedText.string as NSString
        guard selectedRange.location <= text.length else { return nil }
        let location = selectedRange.location
        let mentionRanges = ComposerMentionEditor.mentionRanges(in: attributedText)
        if mentionRanges.contains(where: { NSLocationInRange(location, $0) && location > $0.location && location < $0.upperBound }) {
            return nil
        }

        var scanLocation = location
        while scanLocation > 0 {
            let previousIndex = scanLocation - 1
            let character = text.character(at: previousIndex)
            if character == 64 { // "@"
                let needsBoundaryCheck = previousIndex > 0
                if needsBoundaryCheck {
                    let boundaryCharacter = text.character(at: previousIndex - 1)
                    if !Self.isBoundaryCharacter(boundaryCharacter) {
                        return nil
                    }
                }
                let triggerRange = NSRange(location: previousIndex, length: 1)
                let replacementRange = NSRange(location: previousIndex, length: location - previousIndex)
                if mentionRanges.contains(where: { NSIntersectionRange($0, replacementRange).length > 0 }) {
                    return nil
                }
                let query = text.substring(with: NSRange(location: previousIndex + 1, length: location - previousIndex - 1))
                if query.contains(where: { $0.isWhitespace || $0.isNewline }) {
                    return nil
                }
                return ComposerMentionQueryState(triggerRange: triggerRange, replacementRange: replacementRange, query: query)
            }
            if Self.isTerminatingCharacter(character) {
                return nil
            }
            scanLocation -= 1
        }
        return nil
    }

    private static func isBoundaryCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }

    private static func isTerminatingCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else {
            return true
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

enum ComposerMentionEditor {
    static func mentionRanges(in attributedText: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        attributedText.enumerateAttribute(.composerMention, in: NSRange(location: 0, length: attributedText.length), options: []) { value, range, _ in
            guard value is ComposerMentionEntity else { return }
            ranges.append(range)
        }
        return ranges
    }

    static func mutationForEditing(
        attributedText: NSAttributedString,
        range: NSRange,
        replacementText: String,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> ComposerTextMutation? {
        let mentionRanges = mentionRanges(in: attributedText)
        guard !mentionRanges.isEmpty else { return nil }

        let affectedRanges: [NSRange]
        if range.length > 0 {
            affectedRanges = mentionRanges.filter { NSIntersectionRange($0, range).length > 0 }
        } else {
            let isDeletingBackward = replacementText.isEmpty && range.location > 0
            let isDeletingForward = replacementText.isEmpty && range.location < attributedText.length
            let backwardProbe = NSRange(location: max(0, range.location - 1), length: isDeletingBackward ? 1 : 0)
            let forwardProbe = NSRange(location: range.location, length: isDeletingForward ? 1 : 0)

            affectedRanges = mentionRanges.filter {
                (range.location > $0.location && range.location < $0.upperBound)
                || (backwardProbe.length > 0 && NSIntersectionRange($0, backwardProbe).length > 0)
                || (forwardProbe.length > 0 && NSIntersectionRange($0, forwardProbe).length > 0)
            }
        }

        guard !affectedRanges.isEmpty else { return nil }

        let replacementRange = affectedRanges.dropFirst().reduce(affectedRanges[0]) { partial, next in
            NSUnionRange(partial, next)
        }
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let replacement = NSAttributedString(string: replacementText, attributes: baseAttributes)
        mutable.replaceCharacters(in: replacementRange, with: replacement)
        let location = replacementRange.location + replacement.length
        return ComposerTextMutation(
            attributedText: mutable,
            selectedRange: NSRange(location: location, length: 0)
        )
    }

    static func insertMention(
        in attributedText: NSAttributedString,
        replacementRange: NSRange,
        entity: ComposerMentionEntity,
        baseAttributes: [NSAttributedString.Key: Any],
        mentionAttributes: [NSAttributedString.Key: Any]
    ) -> ComposerTextMutation {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let mentionText = entity.normalizedNickname
        let mention = NSMutableAttributedString(string: mentionText, attributes: mentionAttributes)
        mention.addAttributes(mentionAttributes, range: NSRange(location: 0, length: mention.length))
        mention.append(NSAttributedString(string: " ", attributes: baseAttributes))
        mutable.replaceCharacters(in: replacementRange, with: mention)
        let location = replacementRange.location + mention.length
        return ComposerTextMutation(
            attributedText: mutable,
            selectedRange: NSRange(location: location, length: 0)
        )
    }
}

enum ComposerMentionRangeCodec {
    static func escapedRange(for rawRange: NSRange, in body: String) -> NSRange? {
        let nsBody = body as NSString
        guard rawRange.location >= 0, rawRange.upperBound <= nsBody.length else { return nil }
        let prefix = nsBody.substring(to: rawRange.location)
        let segment = nsBody.substring(with: rawRange)
        let location = prefix.xmlEscaping(reverse: false).count
        let length = segment.xmlEscaping(reverse: false).count
        return NSRange(location: location, length: length)
    }

    static func rawRange(for escapedRange: NSRange, in body: String) -> NSRange? {
        let nsBody = body as NSString
        let bodyLength = nsBody.length
        guard escapedRange.location >= 0,
              escapedRange.length >= 0 else {
            return nil
        }

        var rawStart: Int?
        var rawEnd: Int?

        for rawIndex in 0...bodyLength {
            let escapedLength = nsBody.substring(to: rawIndex).xmlEscaping(reverse: false).count
            if rawStart == nil && escapedLength == escapedRange.location {
                rawStart = rawIndex
            }
            if rawStart != nil && escapedLength == escapedRange.upperBound {
                rawEnd = rawIndex
                break
            }
        }

        guard let rawStart,
              let rawEnd,
              rawStart < rawEnd else {
            return nil
        }

        return NSRange(location: rawStart, length: rawEnd - rawStart)
    }
}

enum ComposerMentionSerializer {
    static func payload(from attributedText: NSAttributedString) -> ComposerMessagePayload {
        let body = attributedText.string
        let references = self.references(from: attributedText, body: body)
        return ComposerMessagePayload(body: body, references: references)
    }

    static func attributedText(
        body: String,
        references: [MessageReferenceStorageItem],
        baseAttributes: [NSAttributedString.Key: Any],
        mentionAttributesProvider: (ComposerMentionEntity) -> [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(string: body, attributes: baseAttributes)
        for reference in references where reference.kind == .mention {
            guard let rawRange = ComposerMentionRangeCodec.rawRange(for: reference.range, in: body),
                  let entity = mentionEntity(from: reference) else {
                continue
            }
            output.addAttributes(mentionAttributesProvider(entity), range: rawRange)
        }
        return output
    }

    private static func references(from attributedText: NSAttributedString, body: String) -> [MessageReferenceStorageItem] {
        var output: [MessageReferenceStorageItem] = []
        for run in mentionRuns(in: attributedText) {
            guard let escapedRange = ComposerMentionRangeCodec.escapedRange(for: run.range, in: body) else {
                continue
            }
            let reference = MessageReferenceStorageItem()
            reference.kind = .mention
            reference.begin = escapedRange.location
            reference.end = escapedRange.location + escapedRange.length
            reference.metadata = [
                "uri": run.entity.uri,
                "node": run.entity.node as Any,
                "memberId": run.entity.memberId,
                "nickname": run.entity.normalizedNickname,
                "jid": run.entity.jid as Any
            ].compactMapValues { $0 }
            reference.url = run.entity.uri
            output.append(reference)
        }
        return output.sorted(by: { $0.begin < $1.begin })
    }

    static func mentionEntity(from reference: MessageReferenceStorageItem) -> ComposerMentionEntity? {
        guard let uri = reference.metadata?["uri"] as? String ?? reference.url else {
            return nil
        }
        let nickname = reference.metadata?["nickname"] as? String ?? ""
        let memberId = reference.metadata?["memberId"] as? String ?? Self.memberId(from: uri) ?? ""
        let jid = reference.metadata?["jid"] as? String
        let node = reference.metadata?["node"] as? String
        return ComposerMentionEntity(
            memberId: memberId,
            nickname: Self.normalizedNickname(
                from: nickname.isEmpty ? reference.bodyFragment(in: reference.messageBody) : nickname
            ),
            uri: uri,
            node: node,
            jid: jid
        )
    }

    private static func memberId(from uri: String) -> String? {
        guard let query = uri.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        let normalizedQuery = query.replacingOccurrences(of: ";", with: "&")
        return normalizedQuery
            .split(separator: "&")
            .compactMap { component -> String? in
                let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == "id" else { return nil }
                return parts[1]
            }
            .first
    }

    private static func normalizedNickname(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    private struct MentionRun {
        let range: NSRange
        let entity: ComposerMentionEntity
    }

    private static func mentionRuns(in attributedText: NSAttributedString) -> [MentionRun] {
        var runs: [MentionRun] = []
        attributedText.enumerateAttribute(.composerMention, in: NSRange(location: 0, length: attributedText.length), options: []) { value, range, _ in
            guard let entity = value as? ComposerMentionEntity,
                  range.length > 0 else {
                return
            }

            if let last = runs.last,
               last.range.upperBound == range.location,
               last.entity.isEquivalent(to: entity) {
                let mergedRange = NSRange(location: last.range.location, length: last.range.length + range.length)
                runs[runs.count - 1] = MentionRun(range: mergedRange, entity: last.entity)
            } else {
                runs.append(MentionRun(range: range, entity: entity))
            }
        }
        return runs
    }
}

private extension MessageReferenceStorageItem {
    var messageBody: String {
        if let realm = self.realm,
           let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: self.messageId) {
            return message.body
        }
        return ""
    }

    func bodyFragment(in body: String) -> String {
        let nsBody = body as NSString
        guard self.begin >= 0, self.end <= nsBody.length, self.begin < self.end else { return "" }
        return nsBody.substring(with: self.range)
    }
}

private extension ComposerMentionEntity {
    var normalizedNickname: String {
        let trimmed = self.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    func isEquivalent(to other: ComposerMentionEntity) -> Bool {
        self.memberId == other.memberId &&
        self.normalizedNickname == other.normalizedNickname &&
        self.uri == other.uri &&
        self.node == other.node &&
        self.jid == other.jid
    }
}
