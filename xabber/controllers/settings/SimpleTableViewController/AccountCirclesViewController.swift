import UIKit

final class AccountCirclesViewController: BaseViewController {

    let placeholderLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "settings_circles_placeholder"
        return label
    }()

    private let iconView: UIImageView = {
        let view = UIImageView()
        view.image = imageLiteral("custom.person.2.square.fill", dimension: 56)
        view.tintColor = .systemGreen
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = false
        return view
    }()

    private let stackView: UIStackView = {
        let view = UIStackView()
        view.axis = .vertical
        view.alignment = .center
        view.spacing = 16
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    func configure(for jid: String) {
        self.jid = jid
        self.owner = jid
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Circles".localizeString(
            id: "settings_account__section_header_circles",
            arguments: []
        )
        view.backgroundColor = .systemGroupedBackground
        placeholderLabel.text = "Roster group management will be available here."

        view.addSubview(stackView)
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
            placeholderLabel.widthAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor,
                constant: -48
            ),
            stackView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }
}
