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

    func testDetailValueRowsPlaceTitleLeftAndValueRight() throws {
        let controller = makeController(datasource: [
            [
                DeviceDetailViewController.Datasource(
                    title: "Client",
                    value: "Xabber Desktop",
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

        XCTAssertEqual(cell.stack.axis, .horizontal)
        XCTAssertEqual(cell.stack.alignment, .center)
        XCTAssertEqual(cell.titleLabel.textAlignment, .left)
        XCTAssertEqual(cell.valueLabel.textAlignment, .right)
    }

    func testSingleLineDetailValueRowsMatchStatusRowHeight() throws {
        let controller = makeController(datasource: [
            [
                DeviceDetailViewController.Datasource(
                    title: "Client",
                    value: "Xabber",
                    key: "client"
                )
            ]
        ])
        let tableView = try XCTUnwrap(firstTableView(in: controller.view))
        let valueCell = try XCTUnwrap(
            controller.tableView(
                tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) as? DeviceDetailValueTableViewCell
        )
        let statusCell = StatusInfoCell(style: .default, reuseIdentifier: StatusInfoCell.cellName)
        statusCell.configure(
            title: "Online",
            status: .online,
            entity: .contact,
            isTemporary: false
        )

        let valueHeight = fittingHeight(for: valueCell)
        let statusHeight = max(44, fittingHeight(for: statusCell))

        XCTAssertEqual(valueHeight, statusHeight, accuracy: 0.5)
    }

    func testFingerprintValueUsesTwoAlignedOctetRows() throws {
        let fingerprint = "0000000011111111222222223333333344444444555555556666666677777777"
        let controller = makeController(datasource: [
            [
                DeviceDetailViewController.Datasource(
                    title: "Fingerprint",
                    value: fingerprint,
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
        let expected = """
        00000000 11111111 22222222 33333333
        44444444 55555555 66666666 77777777
        """
        let text = try XCTUnwrap(cell.valueLabel.text)
        let lines = text.components(separatedBy: "\n")

        XCTAssertEqual(cell.stack.axis, .vertical)
        XCTAssertEqual(text, expected)
        XCTAssertEqual(cell.valueLabel.numberOfLines, 2)
        XCTAssertEqual(lines.count, 2)
        guard lines.count == 2 else {
            return
        }
        XCTAssertEqual(lines[0].count, lines[1].count)
        XCTAssertEqual(lines[0].split(separator: " ").count, lines[1].split(separator: " ").count)
        XCTAssertTrue(lines.joined(separator: " ").split(separator: " ").allSatisfy { $0.count == 8 })
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
        XCTAssertEqual(cell.valueLabel.numberOfLines, 2)
        XCTAssertGreaterThan(fittingHeight, 44)
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
