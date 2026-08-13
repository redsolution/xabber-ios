import XCTest
@testable import xabber

final class QuotaInfoCellTests: XCTestCase {
    func testQuotaTextUsesUnlimitedLabelForNegativeQuota() {
        var formattedValues: [Int] = []
        let text = QuotaInfoCellPresentation.quotaText(
            used: "25 MiB",
            quotaBytes: -1,
            quotaFormatter: { value in
                formattedValues.append(value)
                return "unexpected"
            }
        )

        XCTAssertEqual(text, "25 MiB of Unlimited")
        XCTAssertFalse(text.contains("-1"))
        XCTAssertTrue(formattedValues.isEmpty)
    }

    func testQuotaTextUsesFormattedQuotaForFiniteQuota() {
        let text = QuotaInfoCellPresentation.quotaText(
            used: "25 MiB",
            quotaBytes: 100,
            quotaFormatter: { value in
                XCTAssertEqual(value, 100)
                return "100 MiB"
            }
        )

        XCTAssertEqual(text, "25 MiB of 100 MiB")
    }
}
