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
import MaterialComponents
import CocoaLumberjack

struct PremiumAdvantageItem {
    enum Kind {
        case numbered(String)
        case symbol(String)
    }

    let kind: Kind
    let color: UIColor
    let title: String
    let desc: String?
}

enum PremiumPeriodRowState: Equatable {
    case active
    case scheduled
    case selectable
    case unavailable
}

enum PremiumSubscriptionAction: Equatable {
    case manage
    case subscribe
    case upgrade(planName: String)
    case downgrade(planName: String)
    case unavailable
}

enum PremiumRemoteSectionsState: Equatable {
    case loading
    case loaded(product: APIProduct, source: SubscriptionCatalogSource, warning: String?)
    case empty(warning: String?)
    case error(message: String)
}

enum PremiumEntitlementRefreshState: Equatable {
    case checking
    case resolved
}

struct PremiumCTAState: Equatable {
    let title: String
    let isEnabled: Bool
    let isVisible: Bool

    init(title: String, isEnabled: Bool, isVisible: Bool = true) {
        self.title = title
        self.isEnabled = isEnabled
        self.isVisible = isVisible
    }
}

class PremiumSubscribtionViewController: SimpleBaseViewController, UIScrollViewDelegate {

    typealias PeriodItem = (name: String, period: String, priceId: String, fallbackPrice: String, storeProduct: Product?)

    // MARK: - Constants

    private let accentColor = UIColor(red: 124/255, green: 58/255, blue: 237/255, alpha: 1)
    static let periodSkeletonRowCount = 2
    static let advantageSkeletonRowCount = 2

    // MARK: - Data

    private var selectedPriceId: String?

    private var periodItems: [PeriodItem] = []
    private var currentAPIProduct: APIProduct?

    private static let fullFeatureData: [(icon: String, color: UIColor, title: String, desc: String)] = [
        ("archivebox.fill",     .systemBlue,   "Message Archive",          "Complete message history stored securely without automatic deletion."),
        ("cloud.fill",          .systemOrange, "Extended Cloud Storage",   "Upload and store larger files with increased cloud storage capacity."),
        ("checkmark.seal.fill", .systemGreen,  "Verification Certificate", "Personal digital certificate to verify your identity in conversations."),
        ("flame.fill",          .systemRed,    "Burn Messages",            "Set messages to automatically disappear after a chosen time period."),
        ("lock.shield.fill",    .systemPurple, "Passcode Lock",            "Protect the app with a passcode and option to erase all data on failed attempts."),
    ]

    private static let fullWithoutHostedByXabberFeatureData: [(icon: String, color: UIColor, title: String, desc: String)] = [
        ("archivebox.fill",     .systemBlue,   "Message Archive",          "Complete message history stored securely without automatic deletion."),
        ("cloud.fill",          .systemOrange, "Extended Cloud Storage",   "Upload and store larger files with increased cloud storage capacity."),
        ("checkmark.seal.fill", .systemGreen,  "Verification Certificate", "Personal digital certificate to verify your identity in conversations."),
        ("flame.fill",          .systemRed,    "Burn Messages",            "Set messages to automatically disappear after a chosen time period."),
        ("lock.shield.fill",    .systemPurple, "Passcode Lock",            "Protect the app with a passcode and option to erase all data on failed attempts."),
    ]

    private static let basicFeatureData: [(icon: String, color: UIColor, title: String, desc: String)] = [
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

    private let headerHost = UIView()
    private let periodHost = UIView()
    private let featuresHost = UIView()
    private let manageSectionHeaderHost = UIView()
    private let manageSectionContainer = UIView()
    private let manageSectionHost = UIView()
    private let aboutHost = UIView()
    private let footerHost = UIView()

    private let bottomBar = UIView()
    private let bottomBarTopSeparator = UIView()
    private let subscribeButton = PremiumGradientButton()
    private var bottomBarVisibleConstraints: [NSLayoutConstraint] = []
    private lazy var bottomBarHiddenHeightConstraint = bottomBar.heightAnchor.constraint(equalToConstant: 0)
    private var periodRadioImages: [UIImageView] = []
    private var isNavBarOpaque = false
    private var isProcessing = false
    private var didBuildStaticLayout = false
    var onDismiss: (() -> Void)?

    // Premium state (re-evaluated on each setupSubviews)
    private var hasXabberAccount = false
    private var remoteSectionsState: PremiumRemoteSectionsState = .loading
    private var entitlementRefreshState: PremiumEntitlementRefreshState = .checking
    private var presentationState = SubscriptionPresentationState(
        activeProductId: nil,
        activeExpires: nil,
        scheduledProductId: nil,
        scheduledEffectiveDate: nil,
        hasActiveEntitlement: false
    )

    private lazy var purchaseLoadingOverlay: UIView = {
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

    override func setupSubviews() {
        presentationState = SubscribtionsManager.shared.subscriptionPresentationState(for: self.jid)
        hasXabberAccount = CredentialsManager.getXabberAccountUUID(for: self.jid) != nil
        remoteSectionsState = SubscribtionsManager.shared.apiProduct.map {
            .loaded(product: $0, source: .remote, warning: nil)
        } ?? .loading
        entitlementRefreshState = self.jid.isEmpty ? .resolved : .checking

        buildStaticLayoutOnce()
        renderStaticState()
        renderRemoteSections()
        loadRemoteCatalog()
        loadEntitlementState()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            onDismiss?()
            onDismiss = nil
        }
    }

    private func populatePeriodItems(from apiProduct: APIProduct?) {
        let previousSelectedPriceId = selectedPriceId
        currentAPIProduct = apiProduct
        periodItems.removeAll()
        guard let product = apiProduct else { return }
        for price in product.prices {
            let storeKitProductId = SubscribtionsManager.storeKitProductIdentifier(productId: product.productId, priceId: price.priceId)
            let storeProduct = SubscribtionsManager.shared.products.first(where: { $0.id == storeKitProductId || $0.id == price.priceId })
            periodItems.append((
                name: price.name,
                period: price.period,
                priceId: storeProduct?.id ?? storeKitProductId,
                fallbackPrice: price.price,
                storeProduct: storeProduct
            ))
        }
        periodItems = Self.sortedPeriodItems(periodItems)
        selectedPriceId = Self.resolvedSelectedPriceId(
            previousSelectedPriceId: previousSelectedPriceId,
            items: periodItems,
            activeProductId: presentationState.activeProductId
        )
    }

    private func buildStaticLayoutOnce() {
        guard !didBuildStaticLayout else { return }
        didBuildStaticLayout = true
        scrollView.delegate = self
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        bottomBar.backgroundColor = .systemGroupedBackground
        view.addSubview(bottomBar)

        bottomBarTopSeparator.backgroundColor = .separator
        bottomBar.addSubview(bottomBarTopSeparator)

        subscribeButton.removeTarget(nil, action: nil, for: .touchUpInside)
        subscribeButton.addTarget(self, action: #selector(subscribeTapped), for: .touchUpInside)
        bottomBar.addSubview(subscribeButton)

        for v in [scrollView, contentStack, bottomBar, subscribeButton, bottomBarTopSeparator] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        bottomBarVisibleConstraints = [
            subscribeButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 12),
            subscribeButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            subscribeButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            subscribeButton.bottomAnchor.constraint(equalTo: bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            subscribeButton.heightAnchor.constraint(equalToConstant: 50),

            bottomBarTopSeparator.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBarTopSeparator.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            bottomBarTopSeparator.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            bottomBarTopSeparator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ]
        NSLayoutConstraint.activate(bottomBarVisibleConstraints)

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
        ])

        contentStack.addArrangedSubview(headerHost)
        contentStack.addArrangedSubview(buildSectionHeader("SUBSCRIPTION PERIOD"))
        contentStack.addArrangedSubview(padHorizontally(periodHost))
        contentStack.addArrangedSubview(buildSectionHeader("SUBSCRIPTION ADVANTAGES"))
        contentStack.addArrangedSubview(padHorizontally(featuresHost))
        contentStack.addArrangedSubview(manageSectionHeaderHost)
        contentStack.addArrangedSubview(manageSectionContainer)
        configureManageSectionContainer()
        contentStack.addArrangedSubview(buildSectionHeader("ABOUT XABBER PREMIUM"))
        contentStack.addArrangedSubview(padHorizontally(aboutHost))
        contentStack.addArrangedSubview(footerHost)

        view.addSubview(purchaseLoadingOverlay)
        purchaseLoadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            purchaseLoadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            purchaseLoadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            purchaseLoadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            purchaseLoadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        purchaseLoadingOverlay.isHidden = true
    }

    private func configureManageSectionContainer() {
        manageSectionContainer.addSubview(manageSectionHost)
        manageSectionHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            manageSectionHost.topAnchor.constraint(equalTo: manageSectionContainer.topAnchor),
            manageSectionHost.leadingAnchor.constraint(equalTo: manageSectionContainer.leadingAnchor, constant: 16),
            manageSectionHost.trailingAnchor.constraint(equalTo: manageSectionContainer.trailingAnchor, constant: -16),
            manageSectionHost.bottomAnchor.constraint(equalTo: manageSectionContainer.bottomAnchor),
        ])
    }

    private func renderStaticState() {
        replaceHostedView(in: headerHost, with: buildHeader())
        replaceHostedView(in: manageSectionHeaderHost, with: buildSectionHeader("SUBSCRIPTION MANAGEMENT"))
        replaceHostedView(in: manageSectionHost, with: buildManageSubscriptionCard())
        renderManageSectionVisibility()
        replaceHostedView(in: aboutHost, with: buildAboutCard())
        replaceHostedView(in: footerHost, with: buildFooter())
        renderCallToAction()
    }

    private func renderRemoteSections() {
        switch remoteSectionsState {
        case .loading:
            currentAPIProduct = nil
            periodItems.removeAll()
            replaceHostedView(in: periodHost, with: buildPeriodSkeletonCard())
            replaceHostedView(in: featuresHost, with: buildFeaturesSkeletonCard())
        case .loaded(let product, _, _):
            populatePeriodItems(from: product)
            replaceHostedView(in: periodHost, with: buildPeriodSectionContainer())
            replaceHostedView(in: featuresHost, with: buildFeaturesSectionContainer())
        case .empty:
            currentAPIProduct = nil
            periodItems.removeAll()
            replaceHostedView(in: periodHost, with: buildPeriodSectionContainer())
            replaceHostedView(in: featuresHost, with: buildFeaturesSectionContainer())
        case .error(let message):
            currentAPIProduct = nil
            periodItems.removeAll()
            replaceHostedView(in: periodHost, with: buildInlineMessageCard(message: message, actionTitle: "Retry", action: #selector(retryLoadingTapped)))
            replaceHostedView(in: featuresHost, with: buildInlineMessageCard(message: message))
        }
        renderCallToAction()
    }

    private func loadRemoteCatalog(forceRetry: Bool = false) {
        if forceRetry || !isLoadedCatalogState(remoteSectionsState) {
            remoteSectionsState = .loading
            renderRemoteSections()
        }

        SubscribtionsManager.shared.fetchProducts(jid: self.jid) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.remoteSectionsState = Self.sectionsState(from: result)
                self.renderRemoteSections()
            }
        }
    }

    private func loadEntitlementState() {
        guard self.jid.isNotEmpty else {
            entitlementRefreshState = .resolved
            renderCallToAction()
            return
        }

        entitlementRefreshState = .checking
        renderCallToAction()

        SubscribtionsManager.shared.checkXMPPAccountState(jid: self.jid) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.entitlementRefreshState = .resolved
                self.presentationState = SubscribtionsManager.shared.subscriptionPresentationState(for: self.jid)
                self.renderStaticState()
                self.renderRemoteSections()
            }
        }
    }

    private func replaceHostedView(in host: UIView, with content: UIView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        host.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    private func isLoadedCatalogState(_ state: PremiumRemoteSectionsState) -> Bool {
        if case .loaded = state {
            return true
        }
        return false
    }

    static func sectionsState(from result: SubscriptionCatalogFetchResult) -> PremiumRemoteSectionsState {
        if let product = result.product {
            return .loaded(product: product, source: result.source, warning: result.warningMessage)
        }
        if let errorMessage = result.errorMessage {
            return .error(message: errorMessage)
        }
        return .empty(warning: result.warningMessage)
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
        guard let tag = gesture.view?.tag,
              periodItems.indices.contains(tag),
              Self.isSelectableSelectionTarget(rowState(for: periodItems[tag])) else { return }
        selectedPriceId = periodItems[tag].priceId
        updateSelection()
    }

    @objc private func retryLoadingTapped() {
        loadRemoteCatalog(forceRetry: true)
    }

    @objc private func manageSubscriptionTapped() {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            UIApplication.shared.open(url)
        }
    }

    @objc private func subscribeTapped() {
        guard !isProcessing else { return }

        presentationState = SubscribtionsManager.shared.subscriptionPresentationState(for: self.jid)
        renderStaticState()
        renderRemoteSections()

        switch selectedAction() {
        case .manage:
            manageSubscriptionTapped()
            return
        case .unavailable:
            showAlert(title: "Product Unavailable", message: "This subscription is not available from App Store Connect yet. Please try again later.")
            return
        case .subscribe, .upgrade, .downgrade:
            break
        }

        guard let selectedItem = selectedPeriodItem() else {
            showAlert(title: "Error", message: "Product configuration not found.")
            return
        }

        guard !SubscribtionsManager.isSamePremiumSubscriptionPlan(selectedItem.priceId, presentationState.activeProductId) else {
            updateSelection()
            return
        }

        guard selectedItem.storeProduct != nil else {
            showAlert(title: "Product Unavailable", message: "This subscription is not available from App Store Connect yet. Please try again later.")
            return
        }

        setLoading(true)
        preflightSelectedPurchase(selectedItem) { [weak self] shouldContinue in
            guard let self = self else { return }
            guard shouldContinue else {
                self.setLoading(false)
                return
            }
            self.startPurchase(selectedItem)
        }
    }

    private func preflightSelectedPurchase(_ selectedItem: PeriodItem, completion: @escaping (Bool) -> Void) {
        guard self.jid.isNotEmpty else {
            completion(true)
            return
        }

        SubscribtionsManager.shared.checkXMPPAccountState(jid: self.jid) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(false)
                    return
                }
                self.entitlementRefreshState = .resolved
                self.presentationState = SubscribtionsManager.shared.subscriptionPresentationState(for: self.jid)
                if SubscribtionsManager.isSamePremiumSubscriptionPlan(selectedItem.priceId, self.presentationState.activeProductId) {
                    self.renderStaticState()
                    self.renderRemoteSections()
                    completion(false)
                    return
                }
                completion(true)
            }
        }
    }

    private func startPurchase(_ selectedItem: PeriodItem) {
        guard selectedItem.storeProduct != nil else {
            setLoading(false)
            showAlert(title: "Product Unavailable", message: "This subscription is not available from App Store Connect yet. Please try again later.")
            return
        }

        let accountUUID = self.jid.uuid().uuidString

        SubscribtionsManager.shared.purchase(
            subscribtion: selectedItem.priceId,
            accountUUID: accountUUID,
            jid: self.jid
        ) { [weak self] success, transaction in
            guard let self = self else { return }

            guard success, transaction != nil else {
                DispatchQueue.main.async {
                    self.entitlementRefreshState = .resolved
                    self.presentationState = SubscribtionsManager.shared.subscriptionPresentationState(for: self.jid)
                    if SubscribtionsManager.isSamePremiumSubscriptionPlan(selectedItem.priceId, self.presentationState.activeProductId) {
                        self.setLoading(false)
                        self.renderStaticState()
                        self.renderRemoteSections()
                        return
                    }
                    self.setLoading(false)
                    self.showAlert(title: "Error", message: "Purchase failed. To manage your subscriptions, go to App Store → Settings → Subscriptions.")
                }
                return
            }

            DispatchQueue.main.async {
                self.isProcessing = false
                self.purchaseLoadingOverlay.isHidden = true

                self.presentationState = SubscribtionsManager.shared.subscriptionPresentationState(for: self.jid)
                self.renderStaticState()
                self.renderRemoteSections()

                self.showAlert(title: "Success", message: "Your subscription change has been submitted.")
            }
        }
    }

    // MARK: - Subscription Helpers

    private func selectedPeriodItem() -> PeriodItem? {
        guard let selectedPriceId else {
            return nil
        }
        return periodItems.first(where: { $0.priceId == selectedPriceId })
    }

    private func setLoading(_ loading: Bool) {
        DispatchQueue.main.async {
            self.isProcessing = loading
            self.purchaseLoadingOverlay.isHidden = !loading
            self.renderCallToAction()
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
        renderCallToAction()

        for (index, radio) in periodRadioImages.enumerated() where periodItems.indices.contains(index) {
            let state = rowState(for: periodItems[index])
            Self.applySelectionIndicator(
                to: radio,
                isSelected: periodItems[index].priceId == selectedPriceId && Self.isSelectableSelectionTarget(state),
                isEnabled: Self.isSelectableSelectionTarget(state),
                accentColor: accentColor
            )
        }
    }

    private func renderCallToAction() {
        let ctaState = Self.ctaState(
            remoteState: remoteSectionsState,
            entitlementState: entitlementRefreshState,
            selectedItem: selectedPeriodItem(),
            selectedAction: selectedPeriodItem().map { _ in selectedAction() },
            isProcessing: isProcessing
        )
        subscribeButton.setTitle(ctaState.title, for: .normal)
        subscribeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        subscribeButton.isEnabled = ctaState.isEnabled
        setBottomCTAVisible(ctaState.isVisible)
    }

    private func setBottomCTAVisible(_ isVisible: Bool) {
        bottomBar.isHidden = !isVisible
        bottomBarTopSeparator.isHidden = !isVisible
        subscribeButton.isHidden = !isVisible
        bottomBarVisibleConstraints.forEach { $0.isActive = isVisible }
        bottomBarHiddenHeightConstraint.isActive = !isVisible
        view.setNeedsLayout()
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
        if presentationState.hasActiveEntitlement {
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
        if presentationState.hasActiveEntitlement {
            titleLabel.text = "You're Premium"
            if let expires = presentationState.activeExpires {
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

    private func buildPeriodSectionContainer() -> UIView {
        switch remoteSectionsState {
        case .loaded(_, _, let warning):
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 12
            stack.addArrangedSubview(buildPeriodCard())
            if let warning, warning.isNotEmpty {
                stack.addArrangedSubview(
                    buildInlineMessageCard(
                        message: warning,
                        actionTitle: "Retry",
                        action: #selector(retryLoadingTapped)
                    )
                )
            }
            return stack
        case .empty(let warning):
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 12
            stack.addArrangedSubview(buildInlineMessageCard(message: warning ?? "No subscriptions available right now."))
            return stack
        case .loading:
            return buildPeriodSkeletonCard()
        case .error(let message):
            return buildInlineMessageCard(message: message, actionTitle: "Retry", action: #selector(retryLoadingTapped))
        }
    }

    private func buildPeriodSkeletonCard() -> UIView {
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

        for index in 0..<Self.periodSkeletonRowCount {
            stack.addArrangedSubview(buildPeriodSkeletonRow(isLast: index == Self.periodSkeletonRowCount - 1))
        }

        return card
    }

    private func buildPeriodSkeletonRow(isLast: Bool) -> UIView {
        let row = UIView()

        let radio = SkeletonView(frame: CGRect(square: 26))
        radio.layer.cornerRadius = 13
        radio.layer.masksToBounds = true

        let title = makeSkeletonBar(width: 120, height: 18, cornerRadius: 6)
        let trailing = makeSkeletonBar(width: 72, height: 18, cornerRadius: 6)
        let subtitle = makeSkeletonBar(width: 170, height: 14, cornerRadius: 6)

        let skeletons = [radio, title, trailing, subtitle]
        skeletons.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview($0)
        }

        NSLayoutConstraint.activate([
            radio.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            radio.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            radio.widthAnchor.constraint(equalToConstant: 26),
            radio.heightAnchor.constraint(equalToConstant: 26),

            title.leadingAnchor.constraint(equalTo: radio.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            title.widthAnchor.constraint(equalToConstant: 120),
            title.heightAnchor.constraint(equalToConstant: 18),

            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            trailing.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: 72),
            trailing.heightAnchor.constraint(equalToConstant: 18),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
            subtitle.widthAnchor.constraint(equalToConstant: 170),
            subtitle.heightAnchor.constraint(equalToConstant: 14),
        ])

        if !isLast {
            let sep = UIView()
            sep.backgroundColor = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(sep)
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                sep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            ])
        }

        scheduleSkeletonAnimation(skeletons)

        return row
    }

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

        // Find the monthly price for discount calculation
        let monthlyPrice = monthlyUnitPrice()

        for (i, item) in periodItems.enumerated() {
            let title = item.name
            let price = item.storeProduct?.displayPrice ?? item.fallbackPrice
            let subtitle = buildPeriodSubtitle(for: item)
            let discount = buildDiscount(for: item, monthlyUnitPrice: monthlyPrice)
            let rowState = rowState(for: item)
            let isSelected = item.priceId == selectedPriceId && Self.isSelectableSelectionTarget(rowState)

            let row = buildPeriodRow(
                index: i,
                title: title,
                subtitle: subtitle,
                price: price,
                discount: discount,
                isLast: i == periodItems.count - 1,
                rowState: rowState,
                isSelected: isSelected
            )
            stack.addArrangedSubview(row)
        }

        return card
    }

    private func monthlyUnitPrice() -> Decimal? {
        for item in periodItems {
            if Self.billingMonths(for: item.storeProduct, period: item.period) == 1 {
                return item.storeProduct?.price ?? Self.decimalPrice(from: item.fallbackPrice)
            }
        }
        return nil
    }

    private func buildPeriodSubtitle(for item: PeriodItem) -> String {
        let totalMonths = Self.billingMonths(for: item.storeProduct, period: item.period)
        guard totalMonths > 1,
              let totalPrice = item.storeProduct?.price ?? Self.decimalPrice(from: item.fallbackPrice) else {
            return ""
        }
        let monthlyEquivalent = totalPrice / Decimal(totalMonths)
        let monthlyPriceText = Self.priceText(monthlyEquivalent, storeProduct: item.storeProduct)
        let cadence = totalMonths >= 12 ? "yearly" : "\(totalMonths) months"
        return "Equivalent to \(monthlyPriceText)/month, billed \(cadence)"
    }

    private func buildDiscount(for item: PeriodItem, monthlyUnitPrice: Decimal?) -> String? {
        let totalMonths = Self.billingMonths(for: item.storeProduct, period: item.period)
        guard totalMonths > 1,
              let monthly = monthlyUnitPrice,
              let totalPrice = item.storeProduct?.price ?? Self.decimalPrice(from: item.fallbackPrice) else {
            return nil
        }
        return Self.savingsText(
            totalPrice: totalPrice,
            totalMonths: totalMonths,
            monthlyUnitPrice: monthly,
            storeProduct: item.storeProduct
        )
    }

    private func buildPeriodRow(index: Int, title: String, subtitle: String,
                                price: String, discount: String?, isLast: Bool,
                                rowState: PremiumPeriodRowState,
                                isSelected: Bool) -> UIView {
        let row = UIView()
        row.tag = index
        row.isUserInteractionEnabled = Self.isSelectableSelectionTarget(rowState)
        if row.isUserInteractionEnabled {
            row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(periodTapped)))
        }

        // Radio
        let radio = UIImageView()
        radio.contentMode = .scaleAspectFit
        Self.applySelectionIndicator(
            to: radio,
            isSelected: isSelected,
            isEnabled: Self.isSelectableSelectionTarget(rowState),
            accentColor: accentColor
        )
        periodRadioImages.append(radio)

        // Title label
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .medium)

        // Price / Status badge
        let trailingView: UIView
        switch rowState {
        case .active:
            trailingView = statusBadge(text: "Active", color: .systemGreen)
        case .scheduled:
            trailingView = statusBadge(text: "Scheduled", color: .systemOrange)
        case .selectable, .unavailable:
            let priceLabel = UILabel()
            priceLabel.text = price
            priceLabel.font = .systemFont(ofSize: 17)
            priceLabel.textColor = rowState == .unavailable ? .tertiaryLabel : .secondaryLabel
            trailingView = priceLabel
        }
        trailingView.setContentHuggingPriority(.required, for: .horizontal)
        trailingView.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Title row: title + optional discount badge
        let titleRow = UIStackView(arrangedSubviews: [titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .center

        if case .selectable = rowState, let discount = discount {
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
            trailingView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
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

        if rowState == .unavailable {
            row.alpha = 0.7
        }

        return row
    }

    // MARK: - Features Card

    private func renderManageSectionVisibility() {
        let isVisible = Self.shouldShowManageSubscriptionSection(presentationState)
        manageSectionHeaderHost.isHidden = !isVisible
        manageSectionContainer.isHidden = !isVisible
    }

    private func buildManageSubscriptionCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.clipsToBounds = true
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(manageSubscriptionTapped)))

        let titleLabel = UILabel()
        titleLabel.text = "Manage Subscription"
        titleLabel.font = .systemFont(ofSize: 17, weight: .medium)
        titleLabel.textColor = .label

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.contentMode = .scaleAspectFit
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [titleLabel, chevron] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -15),

            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 18),
        ])

        return card
    }

    private func buildFeaturesSectionContainer() -> UIView {
        switch remoteSectionsState {
        case .loaded(_, _, let warning):
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 12
            stack.addArrangedSubview(buildFeaturesCard())
            if let warning, warning.isNotEmpty {
                stack.addArrangedSubview(buildInlineMessageCard(message: warning))
            }
            return stack
        case .empty:
            return buildFeaturesCard()
        case .loading:
            return buildFeaturesSkeletonCard()
        case .error(let message):
            return buildInlineMessageCard(message: message)
        }
    }

    private func buildFeaturesSkeletonCard() -> UIView {
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

        for index in 0..<Self.advantageSkeletonRowCount {
            stack.addArrangedSubview(buildFeatureSkeletonRow(isLast: index == Self.advantageSkeletonRowCount - 1))
        }

        return card
    }

    private func buildFeatureSkeletonRow(isLast: Bool) -> UIView {
        let row = UIView()

        let iconTile = makeSkeletonBar(width: 40, height: 40, cornerRadius: 8)
        let titleBar = makeSkeletonBar(width: 180, height: 18, cornerRadius: 6)

        let skeletons = [iconTile, titleBar]
        skeletons.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview($0)
        }

        NSLayoutConstraint.activate([
            iconTile.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            iconTile.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            iconTile.widthAnchor.constraint(equalToConstant: 40),
            iconTile.heightAnchor.constraint(equalToConstant: 40),

            titleBar.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 14),
            titleBar.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            titleBar.widthAnchor.constraint(equalToConstant: 180),
            titleBar.heightAnchor.constraint(equalToConstant: 18),
            titleBar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -25),
        ])

        if !isLast {
            let sep = UIView()
            sep.backgroundColor = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(sep)
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor),
                sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                sep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            ])
        }

        scheduleSkeletonAnimation(skeletons)

        return row
    }

    static func advantageItems(
        from apiProduct: APIProduct?,
        hasXabberAccount: Bool,
        jid: String
    ) -> [PremiumAdvantageItem] {
        let includes = (apiProduct?.includes ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isNotEmpty }

        if !includes.isEmpty {
            return includes.map { include in
                PremiumAdvantageItem(
                    kind: .symbol("xabber.checkmark"),
                    color: MDCPalette.green.tint500,
                    title: include,
                    desc: nil
                )
            }
        }

        let featureData: [(icon: String, color: UIColor, title: String, desc: String)]
        if jid.contains("xabber.com") {
            featureData = hasXabberAccount ? Self.fullFeatureData : Self.basicFeatureData
        } else {
            featureData = hasXabberAccount ? Self.fullWithoutHostedByXabberFeatureData : Self.basicFeatureData
        }

        return featureData.map {
            PremiumAdvantageItem(
                kind: .symbol($0.icon),
                color: $0.color,
                title: $0.title,
                desc: $0.desc
            )
        }
    }

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

        let features = Self.advantageItems(
            from: currentAPIProduct,
            hasXabberAccount: hasXabberAccount,
            jid: jid
        )

        for (i, feat) in features.enumerated() {
            stack.addArrangedSubview(
                buildFeatureRow(kind: feat.kind, color: feat.color,
                                title: feat.title, desc: feat.desc,
                                isLast: i == features.count - 1)
            )
        }

        return card
    }

    private func buildFeatureRow(kind: PremiumAdvantageItem.Kind, color: UIColor,
                                 title: String, desc: String?, isLast: Bool) -> UIView {
        let row = UIView()

        // Icon container
        let iconBg = UIView()
        let useTintStyle = Self.usesGreenCheckmarkStyle(for: kind)
        iconBg.backgroundColor = .clear
        iconBg.clipsToBounds = true

        let iconContentView: UIView
        switch kind {
        case .numbered(let value):
            let numberLabel = UILabel()
            numberLabel.text = value
            numberLabel.textColor = .white
            numberLabel.font = .systemFont(ofSize: 17, weight: .medium)
            numberLabel.textAlignment = .center
            iconContentView = numberLabel
        case .symbol(let icon):
            let iconConf = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            let iconView = UIImageView(image: UIImage(named: icon)?.withRenderingMode(.alwaysTemplate) ?? UIImage(systemName: icon, withConfiguration: iconConf))
            iconView.tintColor = useTintStyle ? MDCPalette.green.tint500 : color
            iconView.contentMode = .scaleAspectFit
            iconContentView = iconView
        }
        iconBg.addSubview(iconContentView)

        // Labels
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.numberOfLines = 0

        let descLabel = UILabel()
        descLabel.text = desc
        descLabel.font = .systemFont(ofSize: 14)
        descLabel.textColor = .secondaryLabel
        descLabel.numberOfLines = 0

        for v in [iconBg, iconContentView, titleLabel, descLabel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            if v !== iconContentView { row.addSubview(v) }
        }

        NSLayoutConstraint.activate([
            iconBg.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            iconBg.widthAnchor.constraint(equalToConstant: 40),
            iconBg.heightAnchor.constraint(equalToConstant: 40),

            iconContentView.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconContentView.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            iconContentView.leadingAnchor.constraint(greaterThanOrEqualTo: iconBg.leadingAnchor, constant: 6),
            iconContentView.trailingAnchor.constraint(lessThanOrEqualTo: iconBg.trailingAnchor, constant: -6),
            iconContentView.topAnchor.constraint(greaterThanOrEqualTo: iconBg.topAnchor, constant: 6),
            iconContentView.bottomAnchor.constraint(lessThanOrEqualTo: iconBg.bottomAnchor, constant: -6),

            titleLabel.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
        ])

        if desc?.isEmpty != false {
            descLabel.isHidden = true
            NSLayoutConstraint.activate([
                iconBg.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                iconBg.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 14),
                titleLabel.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
                titleLabel.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 14),
                titleLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            ])
        } else {
            NSLayoutConstraint.activate([
                iconBg.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
                titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
                descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                descLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                descLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
                descLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            ])
        }

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

    private func buildInlineMessageCard(message: String, actionTitle: String? = nil, action: Selector? = nil) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.clipsToBounds = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        stack.addArrangedSubview(label)

        if let actionTitle, let action {
            let button = UIButton(type: .system)
            button.setTitle(actionTitle, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.tintColor = accentColor
            button.contentHorizontalAlignment = .leading
            button.addTarget(self, action: action, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        return card
    }

    // MARK: - About Card

    private func buildAboutCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.clipsToBounds = true

        let label = UILabel()
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label
        label.numberOfLines = 0
        label.attributedText = Self.aboutTextAttributedString(aboutText)

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

        if presentationState.hasActiveEntitlement, let expires = presentationState.activeExpires {
            let expiresLabel = UILabel()
            expiresLabel.text = "Expires: \(expires.formatted(date: .long, time: .shortened))"
            expiresLabel.font = .systemFont(ofSize: 14, weight: .medium)
            expiresLabel.textColor = .secondaryLabel
            expiresLabel.textAlignment = .center
            expiresLabel.numberOfLines = 0
            stack.addArrangedSubview(expiresLabel)
        }

        if let scheduledProductId = presentationState.scheduledProductId {
            let scheduledLabel = UILabel()
            let scheduledName = periodItems.first(where: { $0.priceId == scheduledProductId })?.name ?? scheduledProductId
            let effectiveDate = presentationState.scheduledEffectiveDate?
                .formatted(date: .long, time: .omitted) ?? "the next renewal"
            scheduledLabel.text = "Scheduled change: \(scheduledName) on \(effectiveDate)"
            scheduledLabel.font = .systemFont(ofSize: 14)
            scheduledLabel.textColor = .secondaryLabel
            scheduledLabel.textAlignment = .center
            scheduledLabel.numberOfLines = 0
            stack.addArrangedSubview(scheduledLabel)
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

    private func makeSkeletonBar(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> SkeletonView {
        let view = SkeletonView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.backgroundColor = MDCPalette.grey.tint50
        view.layer.cornerRadius = cornerRadius
        view.layer.masksToBounds = true
        return view
    }

    private func scheduleSkeletonAnimation(_ skeletons: [SkeletonView]) {
        DispatchQueue.main.async {
            skeletons.forEach { $0.startAnimating() }
        }
    }

    static func ctaState(
        remoteState: PremiumRemoteSectionsState,
        entitlementState: PremiumEntitlementRefreshState = .resolved,
        selectedItem: PeriodItem?,
        selectedAction: PremiumSubscriptionAction?,
        isProcessing: Bool
    ) -> PremiumCTAState {
        if isProcessing {
            return PremiumCTAState(title: "Processing…", isEnabled: false)
        }

        if entitlementState == .checking {
            return PremiumCTAState(title: "Checking Subscription…", isEnabled: false)
        }

        switch remoteState {
        case .loading:
            return PremiumCTAState(title: "Loading Plans…", isEnabled: false)
        case .error:
            return PremiumCTAState(title: "Loading Failed", isEnabled: false)
        case .empty:
            return PremiumCTAState(title: "No Plans Available", isEnabled: false)
        case .loaded:
            guard let selectedItem, let selectedAction else {
                return PremiumCTAState(title: "No Plans Available", isEnabled: false, isVisible: false)
            }
            switch selectedAction {
            case .manage:
                return PremiumCTAState(title: "Manage Subscription", isEnabled: false, isVisible: false)
            case .subscribe:
                return PremiumCTAState(title: subscribeTitle(for: selectedItem), isEnabled: true)
            case .upgrade(let planName):
                return PremiumCTAState(title: "Upgrade to \(planName)", isEnabled: true)
            case .downgrade(let planName):
                return PremiumCTAState(title: "Downgrade to \(planName)", isEnabled: true)
            case .unavailable:
                return PremiumCTAState(title: "Product Unavailable", isEnabled: false)
            }
        }
    }

    static func shouldShowManageSubscriptionSection(_ presentationState: SubscriptionPresentationState) -> Bool {
        presentationState.hasActiveEntitlement
    }

    static func usesGreenCheckmarkStyle(for kind: PremiumAdvantageItem.Kind) -> Bool {
        switch kind {
        case .symbol(let icon):
            return icon == "checkmark" || icon == "xabber.checkmark"
        case .numbered:
            return false
        }
    }

    private func rowState(for item: PeriodItem) -> PremiumPeriodRowState {
        Self.rowState(
            forProductId: item.priceId,
            activeProductId: presentationState.activeProductId,
            scheduledProductId: presentationState.scheduledProductId,
            hasStoreProduct: item.storeProduct != nil
        )
    }

    static func rowState(forProductId productId: String,
                         activeProductId: String?,
                         scheduledProductId: String?,
                         hasStoreProduct: Bool) -> PremiumPeriodRowState {
        if SubscribtionsManager.isSamePremiumSubscriptionPlan(productId, activeProductId) {
            return .active
        }
        if let scheduledProductId,
           SubscribtionsManager.isSamePremiumSubscriptionPlan(productId, scheduledProductId),
           !SubscribtionsManager.isSamePremiumSubscriptionPlan(scheduledProductId, activeProductId) {
            return .scheduled
        }
        return hasStoreProduct ? .selectable : .unavailable
    }

    private func selectedAction() -> PremiumSubscriptionAction {
        guard let item = selectedPeriodItem() else { return .unavailable }
        return Self.action(
            selectedName: item.name,
            selectedPriceId: item.priceId,
            selectedHasStoreProduct: item.storeProduct != nil,
            activeProductId: presentationState.activeProductId
        )
    }

    static func action(selectedName: String?,
                       selectedPriceId: String?,
                       selectedHasStoreProduct: Bool,
                       activeProductId: String?) -> PremiumSubscriptionAction {
        guard let selectedName, let selectedPriceId else {
            return .unavailable
        }
        if SubscribtionsManager.isSamePremiumSubscriptionPlan(selectedPriceId, activeProductId) {
            return .manage
        }
        guard selectedHasStoreProduct else {
            return .unavailable
        }
        guard let activeProductId else {
            return .subscribe
        }

        let selectedRank = SubscribtionsManager.premiumPlanRank(for: selectedPriceId)
        let activeRank = SubscribtionsManager.premiumPlanRank(for: activeProductId)

        if selectedRank > 0, selectedRank == activeRank {
            return .manage
        }

        if selectedRank > activeRank {
            return .upgrade(planName: selectedName)
        }
        if selectedRank < activeRank {
            return .downgrade(planName: selectedName)
        }
        return .subscribe
    }

    static func subscribeTitle(for item: PeriodItem) -> String {
        if let product = item.storeProduct {
            return "Subscribe for \(product.displayPrice)"
        }
        if item.fallbackPrice.isNotEmpty {
            return "Subscribe for \(item.fallbackPrice)"
        }
        return "Subscribe"
    }

    static func planRank(for productId: String) -> Int {
        SubscribtionsManager.premiumPlanRank(for: productId)
    }

    private func statusBadge(text: String, color: UIColor) -> UIView {
        let badge = PaddedLabel()
        badge.text = text
        badge.font = .systemFont(ofSize: 13, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = color
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        return badge
    }

    static func resolvedSelectedPriceId(
        previousSelectedPriceId: String?,
        items: [PeriodItem],
        activeProductId: String? = nil
    ) -> String? {
        if let previousSelectedPriceId,
           items.contains(where: {
               $0.priceId == previousSelectedPriceId &&
               !SubscribtionsManager.isSamePremiumSubscriptionPlan($0.priceId, activeProductId)
           }) {
            return previousSelectedPriceId
        }
        return items.first(where: {
            !SubscribtionsManager.isSamePremiumSubscriptionPlan($0.priceId, activeProductId)
        })?.priceId
    }

    static func isSelectableSelectionTarget(_ rowState: PremiumPeriodRowState) -> Bool {
        switch rowState {
        case .selectable, .scheduled:
            return true
        case .active, .unavailable:
            return false
        }
    }

    static func applySelectionIndicator(to imageView: UIImageView, isSelected: Bool, isEnabled: Bool, accentColor: UIColor) {
        imageView.image = UIImage(systemName: selectionIndicatorImageName(isSelected: isSelected))
        if isSelected {
            imageView.tintColor = accentColor
        } else {
            imageView.tintColor = isEnabled ? .tertiaryLabel : .quaternaryLabel
        }
    }

    static func selectionIndicatorImageName(isSelected: Bool) -> String {
        isSelected ? "checkmark.circle.fill" : "circle"
    }

    static func sortedPeriodItems(
        _ items: [PeriodItem]
    ) -> [PeriodItem] {
        items.sorted { lhs, rhs in
            let lhsPrice = lhs.storeProduct?.price ?? decimalPrice(from: lhs.fallbackPrice) ?? 0
            let rhsPrice = rhs.storeProduct?.price ?? decimalPrice(from: rhs.fallbackPrice) ?? 0
            if lhsPrice != rhsPrice {
                return lhsPrice > rhsPrice
            }

            let lhsMonths = billingMonths(for: lhs.storeProduct, period: lhs.period)
            let rhsMonths = billingMonths(for: rhs.storeProduct, period: rhs.period)
            if lhsMonths != rhsMonths {
                return lhsMonths > rhsMonths
            }

            if lhs.priceId != rhs.priceId {
                return lhs.priceId.localizedCaseInsensitiveCompare(rhs.priceId) == .orderedAscending
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func billingMonths(for storeProduct: Product?, period: String) -> Int {
        if let subscription = storeProduct?.subscription {
            switch subscription.subscriptionPeriod.unit {
            case .year:
                return subscription.subscriptionPeriod.value * 12
            case .month:
                return subscription.subscriptionPeriod.value
            default:
                return 0
            }
        }

        switch period.lowercased() {
        case "yearly", "annual", "year":
            return 12
        case "monthly", "month":
            return 1
        default:
            return 0
        }
    }

    static func decimalPrice(from rawValue: String) -> Decimal? {
        guard rawValue.isNotEmpty else { return nil }
        return Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func priceText(_ price: Decimal, storeProduct: Product?) -> String {
        if #available(iOS 16.0, *), let storeProduct {
            return price.formatted(storeProduct.priceFormatStyle)
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: price as NSDecimalNumber) ?? "\(price)"
    }

    static func savingsText(totalPrice: Decimal,
                            totalMonths: Int,
                            monthlyUnitPrice: Decimal,
                            storeProduct: Product?) -> String? {
        guard totalMonths > 1 else { return nil }

        let baselinePrice = monthlyUnitPrice * Decimal(totalMonths)
        guard baselinePrice > totalPrice else { return nil }

        let savings = baselinePrice - totalPrice
        let percentValue = NSDecimalNumber(decimal: savings)
            .dividing(by: NSDecimalNumber(decimal: baselinePrice))
            .multiplying(by: 100)
        let percent = Int(percentValue.doubleValue)
        guard savings > 0, percent > 0 else { return nil }

        return "Save \(priceText(savings, storeProduct: storeProduct)) (\(percent)%)"
    }

    static func aboutTextAttributedString(_ text: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1.43
        paragraphStyle.alignment = .justified
        paragraphStyle.lineHeightMultiple = 1.3
        return NSAttributedString(
            string: text,
            attributes: [
                .paragraphStyle: paragraphStyle,
                .foregroundColor: UIColor.label,
                .font: UIFont.systemFont(ofSize: 15)
            ]
        )
    }

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
