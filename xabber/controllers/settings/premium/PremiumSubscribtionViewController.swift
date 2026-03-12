//
//  PremiumSubscribtionViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 06.03.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import StoreKit
import CocoaLumberjack

class PremiumSubscribtionViewController: SimpleBaseViewController, UIScrollViewDelegate {

    // MARK: - Constants

    private let accentColor = UIColor(red: 124/255, green: 58/255, blue: 237/255, alpha: 1)

    // MARK: - Data

    private var selectedPeriodIndex = 2

    private let periodData: [(title: String, subtitle: String, price: String, discount: String?, buttonTitle: String)] = [
        ("Yearly",    "12 months · $35.88",  "$2.99/month", "-40%", "Subscribe for $35.88"),
        ("Six Months","6 months · $23.94",   "$3.99/month", "-20%", "Subscribe for $23.94"),
        ("Monthly",   "",                    "$4.99/month", nil,    "Subscribe for $4.99/month"),
    ]

    private let fullFeatureData: [(icon: String, color: UIColor, title: String, desc: String)] = [
        ("archivebox.fill",     .systemBlue,   "Message Archive",          "Complete message history stored securely without automatic deletion."),
        ("cloud.fill",          .systemOrange, "Extended Cloud Storage",   "Upload and store larger files with increased cloud storage capacity."),
        ("checkmark.seal.fill", .systemGreen,  "Verification Certificate", "Personal digital certificate to verify your identity in conversations."),
        ("flame.fill",          .systemRed,    "Burn Messages",            "Set messages to automatically disappear after a chosen time period."),
        ("lock.shield.fill",    .systemPurple, "Passcode Lock",            "Protect the app with a passcode and option to erase all data on failed attempts."),
    ]

    private let basicFeatureData: [(icon: String, color: UIColor, title: String, desc: String)] = [
        ("flame.fill",          .systemRed,    "Burn Messages",            "Set messages to automatically disappear after a chosen time period."),
        ("lock.shield.fill",    .systemPurple, "Passcode Lock",            "Protect the app with a passcode and option to erase all data on failed attempts."),
    ]
    
    private let aboutText = """
    Xabber has always been a free, open-source messenger committed to user privacy and security. \
    Premium features require additional server resources — persistent message archives need dedicated \
    storage infrastructure, extended cloud capacity demands powerful servers, and digital verification \
    certificates rely on secure cryptographic services.

    Your subscription directly funds the development and operation of these premium services, while \
    helping us keep the core Xabber experience completely free and ad-free for everyone.
    """

    // MARK: - UI

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.contentInsetAdjustmentBehavior = .never
        sv.alwaysBounceVertical = true
        return sv
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        return stack
    }()

    private let subscribeButton = PremiumGradientButton()
    private var periodRadioImages: [UIImageView] = []
    private var lockedPeriodIndices: Set<Int> = Set()
    private var isNavBarOpaque = false
    private var isProcessing = false

    // Premium state (re-evaluated on each setupSubviews)
    private var isPremiumActive = false
    private var hasXabberAccount = false
    private var purchasedProductIds: Set<String> = Set()
    private var expiresDate: Date? = nil

    private lazy var loadingOverlay: UIView = {
        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        overlay.isHidden = true
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        return overlay
    }()

    // MARK: - Lifecycle

    override func configure() {
        super.configure()
        title = "Xabber Premium"
        view.backgroundColor = .systemGroupedBackground

        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.clear]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.tintColor = .white
    }
    
    func clearViews() {
        view.subviews.forEach({ $0.removeFromSuperview() })
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
    
    override func setupSubviews() {
        clearViews()

        // Evaluate subscription state
        isPremiumActive = SubscribtionsManager.shared.hasActiveSubsription()
        hasXabberAccount = CredentialsManager.getXabberAccountUUID(for: self.jid) != nil
        purchasedProductIds = SubscribtionsManager.shared.getPurchasedProductIds()
        expiresDate = SubscribtionsManager.shared.getExpiresDate()

        scrollView.delegate = self
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        // Bottom bar
        let bottomBar = UIView()
        bottomBar.backgroundColor = .systemGroupedBackground
        view.addSubview(bottomBar)

        // Top separator on bottom bar
        let topSep = UIView()
        topSep.backgroundColor = .separator
        bottomBar.addSubview(topSep)

        if isPremiumActive {
            // "Manage Subscription" plain button
            let manageButton = UIButton(type: .system)
            manageButton.setTitle("Manage Subscription", for: .normal)
            manageButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
            manageButton.tintColor = accentColor
            manageButton.addTarget(self, action: #selector(manageSubscriptionTapped), for: .touchUpInside)
            bottomBar.addSubview(manageButton)
            manageButton.translatesAutoresizingMaskIntoConstraints = false

            for v in [scrollView, contentStack, bottomBar, topSep] as [UIView] {
                v.translatesAutoresizingMaskIntoConstraints = false
            }

            NSLayoutConstraint.activate([
                manageButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
                manageButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
                manageButton.bottomAnchor.constraint(equalTo: bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            ])
        } else {
            subscribeButton.addTarget(self, action: #selector(subscribeTapped), for: .touchUpInside)
            bottomBar.addSubview(subscribeButton)

            for v in [scrollView, contentStack, bottomBar, subscribeButton, topSep] as [UIView] {
                v.translatesAutoresizingMaskIntoConstraints = false
            }

            NSLayoutConstraint.activate([
                subscribeButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
                subscribeButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
                subscribeButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
                subscribeButton.bottomAnchor.constraint(equalTo: bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                subscribeButton.heightAnchor.constraint(equalToConstant: 50),
            ])
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topSep.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            topSep.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            topSep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])

        // Sections
        contentStack.addArrangedSubview(buildHeader())
        contentStack.addArrangedSubview(buildSectionHeader("SUBSCRIPTION PERIOD"))
        contentStack.addArrangedSubview(padHorizontally(buildPeriodCard()))
        contentStack.addArrangedSubview(buildSectionHeader("SUBSCRIPTION ADVANTAGES"))
        contentStack.addArrangedSubview(padHorizontally(buildFeaturesCard()))
        contentStack.addArrangedSubview(buildSectionHeader("ABOUT XABBER PREMIUM"))
        contentStack.addArrangedSubview(padHorizontally(buildAboutCard()))
        contentStack.addArrangedSubview(buildFooter())

        // Loading overlay (on top of everything)
        view.addSubview(loadingOverlay)
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        if !isPremiumActive {
            updateSelection()
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let shouldBeOpaque = scrollView.contentOffset.y > 220
        guard shouldBeOpaque != isNavBarOpaque else { return }
        isNavBarOpaque = shouldBeOpaque

        let appearance = UINavigationBarAppearance()
        if shouldBeOpaque {
            appearance.configureWithDefaultBackground()
            appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
            navigationController?.navigationBar.tintColor = accentColor
        } else {
            appearance.configureWithTransparentBackground()
            appearance.titleTextAttributes = [.foregroundColor: UIColor.clear]
            navigationController?.navigationBar.tintColor = .white
        }
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
    }

    // MARK: - Actions

    @objc private func periodTapped(_ gesture: UITapGestureRecognizer) {
        guard let tag = gesture.view?.tag else { return }
        selectedPeriodIndex = tag
        updateSelection()
    }

    @objc private func manageSubscriptionTapped() {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            UIApplication.shared.open(url)
        }
    }

    @objc private func subscribeTapped() {
        guard !isProcessing else { return }

        guard let productId = productIdForSelectedPeriod() else {
            showAlert(title: "Error", message: "Product configuration not found.")
            return
        }

        setLoading(true)

        // Check if Xabber Account UUID is available (already stored in keychain)
        let accountUUID = CredentialsManager.getXabberAccountUUID(for: self.jid)

        // Purchase via StoreKit 2 (with or without appAccountToken)
        SubscribtionsManager.shared.purchase(
            subscribtion: productId,
            accountUUID: accountUUID
        ) { [weak self] success, transaction in
            guard let self = self else { return }

            guard success, let transaction = transaction else {
                self.setLoading(false)
                self.showAlert(title: "Error", message: "Purchase failed. To manage your subscriptions, go to App Store → Settings → Subscriptions.")
                return
            }

            // Save to Realm + rebuild UI on main thread to avoid cross-thread Realm visibility issues
            DispatchQueue.main.async {
                SubscribtionsManager.shared.saveSubscriptionInfo(
                    productId: transaction.productID,
                    jid: self.jid,
                    accountUUID: accountUUID ?? "",
                    expires: transaction.expirationDate ?? Date(),
                    purchaseDate: transaction.purchaseDate,
                    transactionId: "\(transaction.id)"
                )

                self.isProcessing = false
                self.loadingOverlay.isHidden = true
                self.setupSubviews()

                if accountUUID != nil {
                    self.showAlert(title: "Success", message: "Your premium subscription is now active!") {
                        _ = XabberAccountManager.shared.requestToken(for: self.jid) { token in
                            DDLogDebug("PremiumSubscription: token request result: \(token != nil ? "success" : "failed")")
                        }
                    }
                } else {
                    self.showAlert(title: "Success", message: "Your premium subscription is now active!")
                }
            }
        }
    }

    // MARK: - Subscription Helpers

    private func productIdForSelectedPeriod() -> String? {
        guard let productList = SubscribtionsSecretStore.bundle?.product_list,
              selectedPeriodIndex < productList.count else {
            return nil
        }
        return productList[selectedPeriodIndex]
    }

    private func setLoading(_ loading: Bool) {
        DispatchQueue.main.async {
            self.isProcessing = loading
            self.loadingOverlay.isHidden = !loading
            self.subscribeButton.isEnabled = !loading
        }
    }

    private func showAlert(title: String, message: String, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completion?()
            })
            self.present(alert, animated: true)
        }
    }

    // MARK: - Selection State

    private func updateSelection() {
        subscribeButton.setTitle(periodData[selectedPeriodIndex].buttonTitle, for: .normal)
        subscribeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)

        for (i, radio) in periodRadioImages.enumerated() {
            // Skip locked rows — they keep their green checkmark
            guard !lockedPeriodIndices.contains(i) else { continue }

            if i == selectedPeriodIndex {
                radio.image = UIImage(systemName: "checkmark.circle.fill")
                radio.tintColor = accentColor
            } else {
                radio.image = UIImage(systemName: "circle")
                radio.tintColor = .tertiaryLabel
            }
        }
    }

    // MARK: - Header

    private func buildHeader() -> UIView {
        let header = PremiumGradientView()
        header.gradientLayer.colors = [
            UIColor(red: 58/255,  green: 12/255,  blue: 163/255, alpha: 1).cgColor,
            UIColor(red: 108/255, green: 56/255,  blue: 224/255, alpha: 1).cgColor,
            UIColor(red: 155/255, green: 108/255, blue: 255/255, alpha: 1).cgColor,
        ]
        header.gradientLayer.locations = [0, 0.55, 1]
        header.gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        header.gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        header.clipsToBounds = true

        // Star / Checkmark icon
        let starConfig = UIImage.SymbolConfiguration(pointSize: 72, weight: .thin)
        let starView: UIImageView
        if isPremiumActive {
            starView = UIImageView(image: UIImage(systemName: "checkmark.seal.fill", withConfiguration: starConfig))
            starView.tintColor = UIColor(red: 0.3, green: 1.0, blue: 0.6, alpha: 1)
            starView.layer.shadowColor = UIColor(red: 0.3, green: 1.0, blue: 0.6, alpha: 0.8).cgColor
        } else {
            starView = UIImageView(image: UIImage(systemName: "star.fill", withConfiguration: starConfig))
            starView.tintColor = UIColor(red: 1, green: 0.84, blue: 0.32, alpha: 1)
            starView.layer.shadowColor = UIColor(red: 1, green: 0.84, blue: 0.32, alpha: 0.8).cgColor
        }
        starView.contentMode = .scaleAspectFit
        starView.layer.shadowRadius = 24
        starView.layer.shadowOpacity = 0.6
        starView.layer.shadowOffset = .zero

        // Sparkles
        let sparkles: [(xMult: CGFloat, yMult: CGFloat, size: CGFloat, opacity: CGFloat)] = [
            (0.12, 0.25, 14, 0.6), (0.88, 0.20, 12, 0.5),
            (0.08, 0.55, 10, 0.3), (0.93, 0.50, 16, 0.6),
            (0.25, 0.14, 8,  0.3), (0.75, 0.10, 10, 0.4),
            (0.18, 0.65, 8,  0.25),(0.82, 0.62, 10, 0.35),
            (0.50, 0.10, 12, 0.4), (0.42, 0.72, 6,  0.2),
        ]

        for sp in sparkles {
            let conf = UIImage.SymbolConfiguration(pointSize: sp.size, weight: .regular)
            let sv = UIImageView(image: UIImage(systemName: "sparkle", withConfiguration: conf))
            sv.tintColor = .white
            sv.alpha = sp.opacity
            sv.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(sv)
            NSLayoutConstraint.activate([
                NSLayoutConstraint(item: sv, attribute: .centerX, relatedBy: .equal,
                                   toItem: header, attribute: .trailing, multiplier: sp.xMult, constant: 0),
                NSLayoutConstraint(item: sv, attribute: .centerY, relatedBy: .equal,
                                   toItem: header, attribute: .bottom, multiplier: sp.yMult, constant: 0),
            ])
        }

        // Title
        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        // Subtitle
        let subtitleLabel = UILabel()
        if isPremiumActive {
            titleLabel.text = "You're Premium"
            if let expires = expiresDate {
                subtitleLabel.text = "Your subscription is active until\n\(expires.formatted(date: .long, time: .omitted))"
            } else {
                subtitleLabel.text = "All premium features are unlocked.\nThank you for your support!"
            }
        } else {
            titleLabel.text = "Xabber Premium"
            subtitleLabel.text = "Unlock premium features and support\nopen-source development."
        }
        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        for v in [starView, titleLabel, subtitleLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }

        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 320),

            starView.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            starView.topAnchor.constraint(equalTo: header.topAnchor, constant: 76),
            starView.widthAnchor.constraint(equalToConstant: 100),
            starView.heightAnchor.constraint(equalToConstant: 100),

            titleLabel.topAnchor.constraint(equalTo: starView.bottomAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 32),
            subtitleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -32),
        ])

        return header
    }

    // MARK: - Section Header

    private func buildSectionHeader(_ text: String) -> UIView {
        let container = UIView()
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    // MARK: - Period Card

    private func buildPeriodCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.clipsToBounds = true

        let stack = UIStackView()
        stack.axis = .vertical
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        periodRadioImages.removeAll()
        lockedPeriodIndices.removeAll()

        // Determine which period indices are already purchased
        let productList = SubscribtionsSecretStore.bundle?.product_list ?? []

        for (i, period) in periodData.enumerated() {
            let isLocked = i < productList.count && purchasedProductIds.contains(productList[i])
            if isLocked { lockedPeriodIndices.insert(i) }
            let row = buildPeriodRow(
                index: i,
                title: period.title,
                subtitle: period.subtitle,
                price: period.price,
                discount: period.discount,
                isLast: i == periodData.count - 1,
                locked: isLocked
            )
            stack.addArrangedSubview(row)
        }

        return card
    }

    private func buildPeriodRow(index: Int, title: String, subtitle: String,
                                price: String, discount: String?, isLast: Bool,
                                locked: Bool = false) -> UIView {
        let row = UIView()
        row.tag = index

        if locked {
            // Locked row: no tap, dimmed appearance
            row.isUserInteractionEnabled = false
            row.alpha = 0.5
        } else {
            row.isUserInteractionEnabled = true
            row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(periodTapped)))
        }

        // Radio
        let radio = UIImageView()
        radio.contentMode = .scaleAspectFit
        if locked {
            radio.image = UIImage(systemName: "checkmark.circle.fill")
            radio.tintColor = .systemGreen
        }
        periodRadioImages.append(radio)

        // Title label
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .medium)

        // Price / Active badge
        let trailingView: UIView
        if locked {
            let activeBadge = PaddedLabel()
            activeBadge.text = "Active"
            activeBadge.font = .systemFont(ofSize: 13, weight: .semibold)
            activeBadge.textColor = .white
            activeBadge.backgroundColor = .systemGreen
            activeBadge.layer.cornerRadius = 4
            activeBadge.clipsToBounds = true
            trailingView = activeBadge
        } else {
            let priceLabel = UILabel()
            priceLabel.text = price
            priceLabel.font = .systemFont(ofSize: 17)
            priceLabel.textColor = .secondaryLabel
            trailingView = priceLabel
        }
        trailingView.setContentHuggingPriority(.required, for: .horizontal)
        trailingView.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Title row: title + optional discount badge
        let titleRow = UIStackView(arrangedSubviews: [titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .center

        if !locked, let discount = discount {
            let badge = PaddedLabel()
            badge.text = discount
            badge.font = .systemFont(ofSize: 12, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = .systemGreen
            badge.layer.cornerRadius = 4
            badge.clipsToBounds = true
            badge.setContentHuggingPriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(badge)
        }

        // Subtitle
        let subLabel = UILabel()
        subLabel.text = subtitle
        subLabel.font = .systemFont(ofSize: 14)
        subLabel.textColor = .tertiaryLabel

        for v in [radio, titleRow, trailingView, subLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }

        NSLayoutConstraint.activate([
            radio.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            radio.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            radio.widthAnchor.constraint(equalToConstant: 26),
            radio.heightAnchor.constraint(equalToConstant: 26),

            titleRow.leadingAnchor.constraint(equalTo: radio.trailingAnchor, constant: 12),
            titleRow.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),

            trailingView.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            trailingView.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            trailingView.leadingAnchor.constraint(greaterThanOrEqualTo: titleRow.trailingAnchor, constant: 8),
        ])

        if subtitle.isEmpty {
            subLabel.isHidden = true
            titleRow.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14).isActive = true
        } else {
            NSLayoutConstraint.activate([
                subLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
                subLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 2),
                subLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
            ])
        }

        // Separator
        if !isLast {
            let sep = UIView()
            sep.backgroundColor = .separator
            row.addSubview(sep)
            sep.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
                sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                sep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            ])
        }

        return row
    }

    // MARK: - Features Card

    private func buildFeaturesCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.clipsToBounds = true

        let stack = UIStackView()
        stack.axis = .vertical
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let features = hasXabberAccount ? fullFeatureData : basicFeatureData
        for (i, feat) in features.enumerated() {
            stack.addArrangedSubview(
                buildFeatureRow(icon: feat.icon, color: feat.color,
                                title: feat.title, desc: feat.desc,
                                isLast: i == features.count - 1)
            )
        }

        return card
    }

    private func buildFeatureRow(icon: String, color: UIColor,
                                 title: String, desc: String, isLast: Bool) -> UIView {
        let row = UIView()

        // Icon container
        let iconBg = UIView()
        iconBg.backgroundColor = color
        iconBg.layer.cornerRadius = 8
        iconBg.clipsToBounds = true

        let iconConf = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        let iconView = UIImageView(image: UIImage(systemName: icon, withConfiguration: iconConf))
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconBg.addSubview(iconView)

        // Labels
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let descLabel = UILabel()
        descLabel.text = desc
        descLabel.font = .systemFont(ofSize: 14)
        descLabel.textColor = .secondaryLabel
        descLabel.numberOfLines = 0

        for v in [iconBg, iconView, titleLabel, descLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            if v !== iconView { row.addSubview(v) }
        }

        NSLayoutConstraint.activate([
            iconBg.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            iconBg.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            iconBg.widthAnchor.constraint(equalToConstant: 36),
            iconBg.heightAnchor.constraint(equalToConstant: 36),

            iconView.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            descLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            descLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
        ])

        if !isLast {
            let sep = UIView()
            sep.backgroundColor = .separator
            row.addSubview(sep)
            sep.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                sep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            ])
        }

        return row
    }

    // MARK: - About Card

    private func buildAboutCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.clipsToBounds = true

        let label = UILabel()
        label.text = aboutText
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label
        label.numberOfLines = 0

        card.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        return card
    }

    // MARK: - Footer

    private func buildFooter() -> UIView {
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .center
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])

        if isPremiumActive, let expires = expiresDate {
            let expiresLabel = UILabel()
            expiresLabel.text = "Expires: \(expires.formatted(date: .long, time: .shortened))"
            expiresLabel.font = .systemFont(ofSize: 14, weight: .medium)
            expiresLabel.textColor = .secondaryLabel
            expiresLabel.textAlignment = .center
            expiresLabel.numberOfLines = 0
            stack.addArrangedSubview(expiresLabel)
        }

        let manageLabel = UILabel()
        manageLabel.text = "To manage your subscription, go to\nApp Store → Settings → Subscriptions."
        manageLabel.font = .systemFont(ofSize: 13)
        manageLabel.textColor = .tertiaryLabel
        manageLabel.textAlignment = .center
        manageLabel.numberOfLines = 0
        stack.addArrangedSubview(manageLabel)

        return container
    }

    // MARK: - Helpers

    private func padHorizontally(_ child: UIView, margin: CGFloat = 16) -> UIView {
        let wrapper = UIView()
        wrapper.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: wrapper.topAnchor),
            child.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: margin),
            child.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -margin),
            child.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }
}

// MARK: - Private Views

private class PremiumGradientView: UIView {
    let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.insertSublayer(gradientLayer, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }
}

private class PremiumGradientButton: UIButton {
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        gradientLayer.colors = [
            UIColor(red: 236/255, green: 64/255,  blue: 160/255, alpha: 1).cgColor, // #EC40A0
            UIColor(red: 150/255, green: 80/255,  blue: 238/255, alpha: 1).cgColor, // #9650EE
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.insertSublayer(gradientLayer, at: 0)
        layer.cornerRadius = 25
        clipsToBounds = true
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.8 : 1.0 }
    }
}

private class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right,
                      height: s.height + insets.top + insets.bottom)
    }
}
