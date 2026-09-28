//
//  PasscodeOrBiometricViewController.swift
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import UIKit
import LocalAuthentication
import RxCocoa
import RxSwift

/// The root of the separate, opaque passcode window. It never presents a sheet.
final class PasscodeOrBiometricViewController: SimpleBaseViewController {
    final class KeyboardButton: UIButton {
        let keyId: Int

        init(keyId: Int) {
            self.keyId = keyId
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private enum Flow {
        case unlock
        case verifyLegacy
        case createReplacement
        case confirmReplacement(String)
        case blocked
    }

    internal let pin = BehaviorRelay<String>(value: "")
    var onUnlockSucceeded: (() -> Void)?

    private var flow: Flow = .blocked
    private var credentialIsFullyEnrolled = false
    private var isProcessing = false
    private var authenticationContext: LAContext?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let dotsView = UIStackView()
    private let keyboardView = UIStackView()
    private let retryButton = UIButton(type: .system)
    private var dots: [UIView] = []
    private var biometricsButton: UIButton?

    override func setupSubviews() {
        super.setupSubviews()
        view.backgroundColor = .systemBackground
        view.isOpaque = true
        view.accessibilityIdentifier = "passcode.lock.root"

        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        dotsView.axis = .horizontal
        dotsView.spacing = 16
        dotsView.alignment = .center
        dotsView.distribution = .equalCentering
        dotsView.isAccessibilityElement = true
        dotsView.accessibilityIdentifier = "passcode.lock.indicators"
        for _ in 0..<6 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = .tertiaryLabel
            dot.layer.cornerRadius = 9
            dot.widthAnchor.constraint(equalToConstant: 18).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 18).isActive = true
            dotsView.addArrangedSubview(dot)
            dots.append(dot)
        }

        keyboardView.axis = .vertical
        keyboardView.spacing = 12
        for row in 0..<4 {
            let rowView = UIStackView()
            rowView.axis = .horizontal
            rowView.spacing = 12
            rowView.distribution = .fillEqually
            for column in 0..<3 {
                let index = row * 3 + column
                let button = makeButton(at: index)
                rowView.addArrangedSubview(button)
            }
            keyboardView.addArrangedSubview(rowView)
        }

        retryButton.setTitle(L10n.text("common__action__retry", fallback: "Retry"), for: .normal)
        retryButton.accessibilityIdentifier = "passcode.lock.retry"
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        retryButton.isHidden = true

        let content = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, dotsView, keyboardView, retryButton])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            content.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            keyboardView.widthAnchor.constraint(equalToConstant: 252),
            dotsView.widthAnchor.constraint(equalToConstant: 188)
        ])
    }

    private func makeButton(at index: Int) -> UIButton {
        let button: UIButton
        if index == 9 {
            let biometric = UIButton(type: .system)
            biometric.setImage(imageLiteral("touchid"), for: .normal)
            biometric.addTarget(self, action: #selector(useBiometrics), for: .touchUpInside)
            biometric.accessibilityLabel = L10n.text("settings__title__biometrics", fallback: "Biometrics")
            biometric.accessibilityIdentifier = "passcode.lock.biometrics"
            biometricsButton = biometric
            button = biometric
        } else if index == 11 {
            let backspace = UIButton(type: .system)
            backspace.setImage(imageLiteral("delete.left.fill"), for: .normal)
            backspace.addTarget(self, action: #selector(deleteDigit), for: .touchUpInside)
            backspace.accessibilityLabel = L10n.text("common__action__delete", fallback: "Delete")
            backspace.accessibilityIdentifier = "passcode.lock.delete"
            button = backspace
        } else {
            let digit = index == 10 ? 0 : index + 1
            let key = KeyboardButton(keyId: digit)
            key.setTitle(String(digit), for: .normal)
            key.titleLabel?.font = .preferredFont(forTextStyle: .title2)
            key.setTitleColor(.label, for: .normal)
            key.backgroundColor = .secondarySystemBackground
            key.layer.cornerRadius = 34
            key.accessibilityIdentifier = "passcode.lock.digit.\(digit)"
            key.addTarget(self, action: #selector(enterDigit(_:)), for: .touchUpInside)
            button = key
        }
        button.heightAnchor.constraint(equalToConstant: 68).isActive = true
        return button
    }

    override func subscribe() {
        super.subscribe()
        pin.asObservable()
            .subscribe(onNext: { [weak self] value in self?.pinDidChange(value) })
            .disposed(by: bag)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureFlow()
    }

    deinit {
        authenticationContext?.invalidate()
    }

    func cancelAuthenticationForBackground() {
        authenticationContext?.invalidate()
        authenticationContext = nil
    }

    private func configureFlow() {
        if PasscodeWipeCoordinator.shared.isPending {
            blockForWipe()
            PasscodeWipeCoordinator.shared.resumeIfNeeded { [weak self] success in
                if !success {
                    DispatchQueue.main.async { self?.showBlockedError() }
                }
            }
            return
        }
        do {
            switch try PasscodeCredentialStore.shared.enrollmentState() {
            case .enrolled:
                credentialIsFullyEnrolled = true
                flow = .unlock
            case .pendingFirstEnrollment:
                credentialIsFullyEnrolled = false
                flow = .unlock
            case .legacyNeedsReenrollment:
                credentialIsFullyEnrolled = false
                flow = .verifyLegacy
            case .notEnrolled:
                credentialIsFullyEnrolled = false
                flow = .blocked
            }
            updatePresentation()
        } catch {
            showBlockedError()
        }
    }

    private func updatePresentation() {
        retryButton.isHidden = true
        keyboardView.isHidden = false
        dotsView.isHidden = false
        let allowBiometrics: Bool
        switch flow {
        case .unlock:
            titleLabel.text = L10n.text("passcode__content__enter_passcode", fallback: "Enter passcode")
            allowBiometrics = credentialIsFullyEnrolled &&
                (SettingManager.shared.getKeyBool(for: "", scope: .security, key: "support_touch_id") ?? false)
            updateRemainingSubtitle()
        case .verifyLegacy:
            titleLabel.text = L10n.text("settings__passcode__enter_current_to_change", fallback: "Enter your current passcode to change it")
            allowBiometrics = false
            updateRemainingSubtitle()
        case .createReplacement:
            titleLabel.text = L10n.text("settings__passcode__create_prompt", fallback: "Create a passcode to protect your data")
            subtitleLabel.text = ""
            allowBiometrics = false
        case .confirmReplacement:
            titleLabel.text = L10n.text("settings__passcode__confirm_prompt", fallback: "Confirm your new passcode")
            subtitleLabel.text = ""
            allowBiometrics = false
        case .blocked:
            showBlockedError()
            return
        }
        biometricsButton?.isHidden = !allowBiometrics
        updateDots(count: pin.value.count)
    }

    private func updateRemainingSubtitle() {
        do {
            guard let remaining = try PasscodeCredentialStore.shared.remainingAttempts() else {
                subtitleLabel.text = ""
                return
            }
            if remaining == 0 {
                beginTerminalWipe()
                return
            }
            let showAttempts = SettingManager.shared.get(bool: SettingsViewController.Datasource.Keys.showAttempts.rawValue)
            subtitleLabel.text = showAttempts ? L10n.plural(
                "passcode_or_biometric__text__value_attempts_left",
                count: remaining,
                fallback: "%lld attempts left"
            ) : ""
        } catch {
            showBlockedError()
        }
    }

    private func pinDidChange(_ value: String) {
        updateDots(count: value.count)
        guard value.count == 6, !isProcessing else { return }
        switch flow {
        case .unlock, .verifyLegacy:
            verifyPIN(value)
        case .createReplacement:
            flow = .confirmReplacement(value)
            pin.accept("")
            updatePresentation()
        case .confirmReplacement(let first):
            guard first == value else {
                pin.accept("")
                flow = .createReplacement
                updatePresentation()
                subtitleLabel.text = L10n.text("passcode__presentation_call__passcodes_did_not_match_try_again", fallback: "Passcodes did not match. Try again.")
                return
            }
            saveReplacement(value)
        case .blocked:
            break
        }
    }

    private func verifyPIN(_ value: String) {
        isProcessing = true
        let wasLegacy: Bool
        if case .verifyLegacy = flow { wasLegacy = true } else { wasLegacy = false }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PasscodeCredentialStore.shared.verify(value) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                self.pin.accept("")
                switch result {
                case .success(.matched):
                    if wasLegacy {
                        self.flow = .createReplacement
                        self.updatePresentation()
                    } else if !PasscodeWipeCoordinator.shared.isPending {
                        self.authenticationContext?.invalidate()
                        self.onUnlockSucceeded?()
                    }
                case .success(.incorrect):
                    self.updateRemainingSubtitle()
                case .success(.exhausted):
                    self.beginTerminalWipe()
                case .failure:
                    self.showBlockedError()
                }
            }
        }
    }

    private func saveReplacement(_ value: String) {
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let limit = try PasscodeCredentialStore.shared.attemptLimit()
                try PasscodeCredentialStore.shared.enroll(value, attempts: limit)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pin.accept("")
                self.isProcessing = false
                switch result {
                case .success:
                    self.flow = .unlock
                    self.onUnlockSucceeded?()
                case .failure:
                    self.showBlockedError()
                }
            }
        }
    }

    private func beginTerminalWipe() {
        blockForWipe()
        ApplicationStateManager.shared.beginTerminalWipe()
    }

    private func blockForWipe() {
        authenticationContext?.invalidate()
        flow = .blocked
        pin.accept("")
        titleLabel.text = L10n.text("settings__title__passcode_lock", fallback: "Passcode Lock")
        subtitleLabel.text = L10n.text("passcode__content__removing_data", fallback: "Removing local data…")
        keyboardView.isHidden = true
        dotsView.isHidden = true
        retryButton.isHidden = true
    }

    private func showBlockedError() {
        authenticationContext?.invalidate()
        flow = .blocked
        pin.accept("")
        titleLabel.text = L10n.text("settings__title__passcode_lock", fallback: "Passcode Lock")
        subtitleLabel.text = L10n.text("common__error__internal", fallback: "Internal error")
        keyboardView.isHidden = true
        dotsView.isHidden = true
        retryButton.isHidden = false
    }

    private func updateDots(count: Int) {
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = index < count ? .label : .tertiaryLabel
        }
        dotsView.accessibilityLabel = L10n.format(
            "passcode__accessibility__digits_entered_format",
            fallback: "Digits entered: %@",
            arguments: [String(count)]
        )
    }

    @objc private func enterDigit(_ sender: KeyboardButton) {
        guard !isProcessing, pin.value.count < 6 else { return }
        switch flow {
        case .blocked: return
        default: break
        }
        pin.accept(pin.value + String(sender.keyId))
        FeedbackManager.shared.tap()
    }

    @objc private func deleteDigit() {
        guard !isProcessing, !pin.value.isEmpty else { return }
        pin.accept(String(pin.value.dropLast()))
        FeedbackManager.shared.tap()
    }

    @objc private func useBiometrics() {
        guard !isProcessing, !PasscodeWipeCoordinator.shared.isPending else { return }
        guard case .unlock = flow else { return }
        guard SettingManager.shared.getKeyBool(for: "", scope: .security, key: "support_touch_id") ?? false else { return }
        do {
            guard try PasscodeCredentialStore.shared.enrollmentState() == .enrolled,
                  try PasscodeCredentialStore.shared.remainingAttempts() != 0 else { return }
        } catch {
            showBlockedError()
            return
        }
        let context = LAContext()
        authenticationContext = context
        context.localizedCancelTitle = L10n.text("passcode__content__enter_passcode", fallback: "Enter passcode")
        let reason = L10n.format(
            "passcode__biometrics__unlock_app_format", fallback: "Unlock %@",
            arguments: [String(describing: CommonConfigManager.shared.config.app_name)]
        )
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self, success, self.authenticationContext === context,
                      !PasscodeWipeCoordinator.shared.isPending else { return }
                do {
                    guard try PasscodeCredentialStore.shared.enrollmentState() == .enrolled,
                          try PasscodeCredentialStore.shared.remainingAttempts() != 0 else { return }
                    try PasscodeCredentialStore.shared.resetRemainingAttemptsAfterSuccessfulAuthentication()
                    self.onUnlockSucceeded?()
                } catch {
                    self.showBlockedError()
                }
            }
        }
    }

    @objc private func retry() {
        if PasscodeWipeCoordinator.shared.isPending {
            blockForWipe()
            PasscodeWipeCoordinator.shared.resumeIfNeeded { [weak self] success in
                if !success {
                    DispatchQueue.main.async { self?.showBlockedError() }
                }
            }
        } else {
            configureFlow()
        }
    }
}
