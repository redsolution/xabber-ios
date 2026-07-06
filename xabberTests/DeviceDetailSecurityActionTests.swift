import XCTest
@testable import xabber

@MainActor
final class DeviceDetailSecurityActionTests: XCTestCase {
    func testTerminateRowIsButtonLikeAndRequiresConfirmation() throws {
        let controller = makeController(datasource: [
            [
                DeviceDetailViewController.Datasource(
                    title: "Terminate session",
                    value: nil,
                    key: "terminate"
                )
            ]
        ])
        let tableView = try XCTUnwrap(firstTableView(in: controller.view))
        let cell = try XCTUnwrap(
            controller.tableView(
                tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) as? ButtonTableViewCell
        )

        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))
        XCTAssertFalse(cell.accessibilityTraits.contains(.staticText))
        XCTAssertEqual(cell.accessibilityIdentifier, "device_detail_terminate_session_button")
        XCTAssertEqual(cell.titleLabel.text, "Terminate session")
        XCTAssertTrue(cell.titleLabel.adjustsFontForContentSizeCategory)
        XCTAssertEqual(cell.titleLabel.numberOfLines, 0)
        XCTAssertGreaterThanOrEqual(cell.minimumEffectiveHeight, 44)
        XCTAssertTrue(cell.accessibilityHint?.lowercased().contains("confirmation") ?? false)
    }

    func testTerminateConfirmationUsesSessionLanguageAndCanCancel() {
        let confirmation = DeviceDetailSessionTerminationConfirmation.default(uid: "device-session-1")
        let exposedText = [
            confirmation.title,
            confirmation.message,
            confirmation.confirmTitle,
            confirmation.cancelTitle
        ].joined(separator: " ").lowercased()
        let message = confirmation.message.lowercased()

        XCTAssertFalse(exposedText.contains("revoke"))
        XCTAssertTrue(message.contains("selected device session"))
        XCTAssertTrue(message.contains("current device remains signed in"))
        XCTAssertTrue(message.contains("account and server data is not deleted"))
        XCTAssertEqual(
            confirmation.effect(confirmed: true),
            .terminateSession(uid: "device-session-1")
        )
        XCTAssertEqual(
            confirmation.effect(confirmed: false),
            .none
        )
    }

    func testLongDetailValueSelfSizesAndWraps() throws {
        let controller = makeController(datasource: [
            [
                DeviceDetailViewController.Datasource(
                    title: "Client",
                    value: String(repeating: "Long localized desktop client metadata ", count: 6),
                    key: "client"
                )
            ]
        ])
        let tableView = try XCTUnwrap(firstTableView(in: controller.view))
        let cell = try XCTUnwrap(
            controller.tableView(
                tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) as? DeviceDetailValueTableViewCell
        )
        let fittingHeight = fittingHeight(for: cell)

        XCTAssertTrue(cell.titleLabel.adjustsFontForContentSizeCategory)
        XCTAssertTrue(cell.valueLabel.adjustsFontForContentSizeCategory)
        XCTAssertEqual(cell.titleLabel.numberOfLines, 0)
        XCTAssertEqual(cell.valueLabel.numberOfLines, 0)
        XCTAssertGreaterThan(fittingHeight, 44)
    }

    func testFingerprintValueRemainsReadableAtAccessibilitySizes() throws {
        let controller = makeController(datasource: [
            [
                DeviceDetailViewController.Datasource(
                    title: "Fingerprint",
                    value: String(repeating: "ABCD EFGH IJKL MNOP ", count: 5),
                    key: "omemo_fingerprint"
                )
            ]
        ])
        let tableView = try XCTUnwrap(firstTableView(in: controller.view))
        let cell = try XCTUnwrap(
            controller.tableView(
                tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) as? DeviceDetailValueTableViewCell
        )
        let fittingHeight = fittingHeight(for: cell)

        XCTAssertTrue(cell.valueLabel.adjustsFontForContentSizeCategory)
        XCTAssertEqual(cell.valueLabel.numberOfLines, 0)
        XCTAssertGreaterThan(fittingHeight, 84)
    }

    func testPrimaryRowActionsPreserveExistingNavigationBehavior() {
        let controller = makeController(datasource: [
            [
                DeviceDetailViewController.Datasource(
                    title: "Last seen",
                    value: "Online",
                    key: "status"
                )
            ],
            [
                DeviceDetailViewController.Datasource(
                    title: "Resource",
                    value: "desktop",
                    key: "resource"
                )
            ],
            [
                DeviceDetailViewController.Datasource(
                    title: "Rename",
                    value: nil,
                    key: "rename"
                )
            ],
            [
                DeviceDetailViewController.Datasource(
                    title: "Terminate session",
                    value: nil,
                    key: "terminate"
                )
            ]
        ])

        XCTAssertEqual(
            controller.deviceDetailPrimaryAction(at: IndexPath(row: 0, section: 0)),
            .showStatusResource
        )
        XCTAssertEqual(
            controller.deviceDetailPrimaryAction(at: IndexPath(row: 0, section: 1)),
            .showAccountConnection
        )
        XCTAssertEqual(
            controller.deviceDetailPrimaryAction(at: IndexPath(row: 0, section: 2)),
            .rename
        )
        XCTAssertEqual(
            controller.deviceDetailPrimaryAction(at: IndexPath(row: 0, section: 3)),
            .terminateSession(DeviceDetailSessionTerminationConfirmation.default(uid: ""))
        )
    }

    private func makeController(
        datasource: [[DeviceDetailViewController.Datasource]]
    ) -> DeviceDetailViewController {
        let controller = DeviceDetailViewController()
        controller.uid = ""
        controller.loadViewIfNeeded()
        controller.datasource = datasource
        return controller
    }

    private func firstTableView(in view: UIView) -> UITableView? {
        if let tableView = view as? UITableView {
            return tableView
        }

        for subview in view.subviews {
            if let tableView = firstTableView(in: subview) {
                return tableView
            }
        }

        return nil
    }

    private func fittingHeight(for cell: UITableViewCell) -> CGFloat {
        cell.bounds = CGRect(x: 0, y: 0, width: 320, height: 1)
        cell.contentView.bounds = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return cell.contentView.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }
}
