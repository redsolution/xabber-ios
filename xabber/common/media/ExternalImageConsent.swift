import UIKit

@MainActor
enum ExternalImageConsent {
    static var title: String {
        L10n.text("external_image__show", fallback: "Show image")
    }

    static func present(
        for url: URL,
        owner: String,
        from view: UIView,
        shouldGrant: @escaping () -> Bool = { true },
        onGranted: @escaping () -> Void
    ) {
        let router = PrivacyProxyMediaRouter.shared
        guard router.canRequestDirectImage(url, owner: owner),
              let host = url.host, view.window != nil else { return }

        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        guard let controller = responder as? UIViewController,
              controller.presentedViewController == nil else { return }

        YesNoPresenter().present(
            in: controller, style: .alert, title: title,
            message: L10n.format(
                "external_image__direct_warning",
                fallback: "Loading this image connects directly to %@ and reveals your IP address to that site.",
                arguments: [host]
            ),
            yesText: title,
            noText: L10n.text("common__action__cancel", fallback: "Cancel"),
            animated: true,
            confirmAfterDismissal: true
        ) { accepted in
            guard accepted, shouldGrant(), router.grantDirectImage(url, owner: owner) else { return }
            onGranted()
        }
    }
}

final class ExternalImageConsentButton: UIButton {
    var onTap: (() -> Void)?
    private var onProxyRecovery: ((String) -> Void)?

    init(in container: UIView) {
        super.init(frame: .zero)
        var appearance = UIButton.Configuration.filled()
        appearance.title = ExternalImageConsent.title
        appearance.titleLineBreakMode = .byWordWrapping
        appearance.buttonSize = .small
        appearance.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        configuration = appearance
        titleLabel?.textAlignment = .center
        accessibilityIdentifier = "chat.media.photo.show-external"
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        NotificationCenter.default.addObserver(
            self, selector: #selector(proxyAvailabilityDidChange),
            name: .privacyProxyAvailabilityDidChange, object: nil
        )
        container.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: container.centerXAnchor),
            centerYAnchor.constraint(equalTo: container.centerYAnchor),
            leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 4),
            trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        isHidden = true
        onTap = nil
        onProxyRecovery = nil
    }

    func retryWhenProxyRecovers(for owner: String, retry: @escaping () -> Void) {
        onProxyRecovery = { changedOwner in
            guard owner == changedOwner,
                  PrivacyProxyMediaRouter.shared.canResolveImagesThroughProxy(owner: owner),
                  let account = AccountManager.shared.find(for: owner),
                  case .reachable = account.disco.privacyProxyAvailability else { return }
            retry()
        }
    }

    @objc private func proxyAvailabilityDidChange(_ notification: Notification) {
        guard window != nil, !isHidden, let owner = notification.userInfo?["owner"] as? String else { return }
        onProxyRecovery?(owner)
    }

    @objc private func tapped() {
        onTap?()
    }
}
