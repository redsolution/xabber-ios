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

    func testLegendWrapsAllSixCategoriesIntoTwoRows() {
        XCTAssertEqual(
            QuotaInfoCellPresentation.legendRows.map { $0.map(\.rawValue) },
            [
                ["images", "videos", "voice"],
                ["calls", "files", "avatars"]
            ]
        )
    }

    func testChartUsageKeepsVoiceAndCallsAsSeparateSegments() {
        let item = AccountQuotaStorageItem()
        item.imagesBytes = 1
        item.videosBytes = 2
        item.voicesBytes = 3
        item.audioBytes = 4
        item.filesBytes = 5
        item.avatarsBytes = 6

        let usage = QuotaInfoCellPresentation.usageBytes(from: item)

        XCTAssertEqual(usage[.images], 1)
        XCTAssertEqual(usage[.videos], 2)
        XCTAssertEqual(usage[.voice], 3)
        XCTAssertEqual(usage[.calls], 4)
        XCTAssertEqual(usage[.files], 5)
        XCTAssertEqual(usage[.avatars], 6)
    }

    func testInlineIncreaseOfferExpandsQuotaCardAtPhoneWidth() {
        let premiumCell = QuotaInfoCell(style: .default, reuseIdentifier: nil)
        premiumCell.setup(
            title: "Media Gallery",
            owner: "owner@example.com",
            displayState: .loading,
            increaseStorage: nil
        )

        let basicCell = QuotaInfoCell(style: .default, reuseIdentifier: nil)
        basicCell.setup(
            title: "Media Gallery",
            owner: "owner@example.com",
            displayState: .loading,
            increaseStorage: .inlineState(hasActivePremium: false)
        )

        let fittingSize = CGSize(width: 350, height: UIView.layoutFittingCompressedSize.height)
        let premiumHeight = premiumCell.contentView.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let basicHeight = basicCell.contentView.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        XCTAssertGreaterThan(basicHeight, premiumHeight + 60)
    }
}
