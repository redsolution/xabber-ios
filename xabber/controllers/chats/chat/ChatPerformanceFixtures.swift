//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation

#if DEBUG
enum ChatPerformanceFixtureScale: String, CaseIterable {
    case small
    case tenThousand
    case hundredThousand
    case million

    var rowCount: Int {
        switch self {
        case .small:
            return 100
        case .tenThousand:
            return 10_000
        case .hundredThousand:
            return 100_000
        case .million:
            return 1_000_000
        }
    }
}

struct ChatPerformanceThinFixtureRow: Equatable {
    let ordinal: Int
    let timestampSeconds: Int64
    let bodyVariant: Int
}

protocol ChatPerformanceFixturePersisting: AnyObject {
    var isEphemeral: Bool { get }
    var persistedRowCount: Int { get }

    func prepare(totalRowCount: Int) throws
    func beginBatch(_ range: Range<Int>) throws
    func persist(_ row: ChatPerformanceThinFixtureRow) throws
    func endBatch() throws
    @discardableResult func cleanup() throws -> Int
}

enum ChatPerformanceFixtureError: Error, Equatable {
    case invalidBatchSize(Int)
    case storeIsNotEphemeral
    case persistedRowCountMismatch(expected: Int, actual: Int)
}

struct ChatPerformanceFixtureGenerationReport: Equatable {
    let requestedRowCount: Int
    let persistedRowCount: Int
    let batchSize: Int
    let batchCount: Int
    let maximumGeneratedRowsInMemory: Int
}

struct ChatPerformanceFixtureRun<Result> {
    let result: Result
    let generation: ChatPerformanceFixtureGenerationReport
    let deletedRowCount: Int
    let remainingRowCountAfterCleanup: Int
}

enum ChatPerformanceFixtureGenerator {
    private static let baseTimestampSeconds: Int64 = 1_700_000_000

    static func withFixture<Result>(
        scale: ChatPerformanceFixtureScale,
        batchSize: Int,
        store: ChatPerformanceFixturePersisting,
        body: (ChatPerformanceFixtureGenerationReport) throws -> Result
    ) throws -> ChatPerformanceFixtureRun<Result> {
        guard batchSize > 0 else {
            throw ChatPerformanceFixtureError.invalidBatchSize(batchSize)
        }
        guard store.isEphemeral else {
            throw ChatPerformanceFixtureError.storeIsNotEphemeral
        }

        let requestedRowCount = scale.rowCount

        do {
            try store.prepare(totalRowCount: requestedRowCount)
            var lowerBound = 0
            var batchCount = 0

            while lowerBound < requestedRowCount {
                let upperBound = min(requestedRowCount, lowerBound + batchSize)
                let range = lowerBound..<upperBound
                try store.beginBatch(range)

                for ordinal in range {
                    let row = ChatPerformanceThinFixtureRow(
                        ordinal: ordinal,
                        timestampSeconds: baseTimestampSeconds + Int64(ordinal),
                        bodyVariant: ordinal % 7
                    )
                    try autoreleasepool {
                        try store.persist(row)
                    }
                }

                try store.endBatch()
                lowerBound = upperBound
                batchCount += 1
            }

            let persistedRowCount = store.persistedRowCount
            guard persistedRowCount == requestedRowCount else {
                throw ChatPerformanceFixtureError.persistedRowCountMismatch(
                    expected: requestedRowCount,
                    actual: persistedRowCount
                )
            }

            let generation = ChatPerformanceFixtureGenerationReport(
                requestedRowCount: requestedRowCount,
                persistedRowCount: persistedRowCount,
                batchSize: batchSize,
                batchCount: batchCount,
                maximumGeneratedRowsInMemory: requestedRowCount > 0 ? 1 : 0
            )
            let result = try body(generation)
            let deletedRowCount = try store.cleanup()

            return ChatPerformanceFixtureRun(
                result: result,
                generation: generation,
                deletedRowCount: deletedRowCount,
                remainingRowCountAfterCleanup: store.persistedRowCount
            )
        } catch {
            _ = try? store.cleanup()
            throw error
        }
    }
}

struct ChatPerformanceFixtureFeature: OptionSet {
    let rawValue: UInt32

    static let shortText = Self(rawValue: 1 << 0)
    static let longText = Self(rawValue: 1 << 1)
    static let utf16Markup = Self(rawValue: 1 << 2)
    static let forwarded = Self(rawValue: 1 << 3)
    static let oneImage = Self(rawValue: 1 << 4)
    static let fiveImages = Self(rawValue: 1 << 5)
    static let video = Self(rawValue: 1 << 6)
    static let location = Self(rawValue: 1 << 7)
    static let contact = Self(rawValue: 1 << 8)
    static let voice = Self(rawValue: 1 << 9)
    static let edited = Self(rawValue: 1 << 10)
    static let read = Self(rawValue: 1 << 11)
    static let error = Self(rawValue: 1 << 12)

    static let allRequired: Self = [
        .shortText,
        .longText,
        .utf16Markup,
        .forwarded,
        .oneImage,
        .fiveImages,
        .video,
        .location,
        .contact,
        .voice,
        .edited,
        .read,
        .error
    ]
}

struct ChatPerformanceRichFixtureRow: Equatable {
    let ordinal: Int
    let body: String
    let markupRanges: [NSRange]
    let features: ChatPerformanceFixtureFeature
}

enum ChatPerformanceRichFixture {
    static let rows: [ChatPerformanceRichFixtureRow] = {
        let markedBody = "prefix 😀 marked suffix"
        let markedRange = (markedBody as NSString).range(of: "😀 marked")

        return [
            row(0, body: "short", features: .shortText),
            row(1, body: String(repeating: "deterministic long content ", count: 192), features: .longText),
            row(2, body: markedBody, ranges: [markedRange], features: .utf16Markup),
            row(3, body: "forward", features: .forwarded),
            row(4, body: "image-one", features: .oneImage),
            row(5, body: "image-five", features: .fiveImages),
            row(6, body: "video", features: .video),
            row(7, body: "location", features: .location),
            row(8, body: "contact", features: .contact),
            row(9, body: "voice", features: .voice),
            row(10, body: "edited", features: .edited),
            row(11, body: "read", features: .read),
            row(12, body: "error", features: .error)
        ]
    }()

    private static func row(
        _ ordinal: Int,
        body: String,
        ranges: [NSRange] = [],
        features: ChatPerformanceFixtureFeature
    ) -> ChatPerformanceRichFixtureRow {
        ChatPerformanceRichFixtureRow(
            ordinal: ordinal,
            body: body,
            markupRanges: ranges,
            features: features
        )
    }
}
#endif
