import XCTest
@testable import xabber

final class ChatRenderOperationCounterTests: XCTestCase {
    func testCounterProvesRowsAndAppIssuedOffsetMutationCounts() {
        let counter = ChatRenderOperationCounter(isEnabled: true)

        counter.record(.rowsEnumerated, by: 80)
        counter.record(.offsetMutations)
        counter.record(.offsetMutations)

        let snapshot = counter.snapshot()
        XCTAssertEqual(snapshot[.rowsEnumerated], 80)
        XCTAssertEqual(snapshot[.offsetMutations], 2)
    }

    func testDisabledCounterDoesNotEvaluateLazyAmount() {
        let counter = ChatRenderOperationCounter(isEnabled: false)
        var evaluationCount = 0

        func expensiveAmount() -> Int {
            evaluationCount += 1
            return 42
        }

        counter.record(.richSnapshotsBuilt, by: expensiveAmount())

        XCTAssertEqual(evaluationCount, 0)
        XCTAssertEqual(counter.snapshot()[.richSnapshotsBuilt], 0)
    }

    func testSnapshotUsesOnlyClosedPrivacySafeOperationNames() {
        let counter = ChatRenderOperationCounter(isEnabled: true)
        ChatRenderOperation.allCases.forEach { counter.record($0) }

        let snapshot = counter.snapshot()

        XCTAssertTrue(snapshot.isPrivacySafe)
        XCTAssertEqual(Set(snapshot.sortedFieldNames), Set(ChatRenderOperation.allCases.map(\.rawValue)))
        XCTAssertTrue(snapshot.unsafeFieldNames.isEmpty)
    }

    func testConcurrentRecordingIsLossless() {
        let counter = ChatRenderOperationCounter(isEnabled: true)

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            counter.record(.textMeasurements)
        }

        XCTAssertEqual(counter.snapshot()[.textMeasurements], 1_000)
    }

    func testGaugeDecrementIsIdempotentAndNeverNegative() {
        let counter = ChatRenderOperationCounter(isEnabled: true)

        counter.incrementGauge(.activeTasks)
        counter.decrementGauge(.activeTasks)
        counter.decrementGauge(.activeTasks)

        XCTAssertEqual(counter.snapshot()[.activeTasks], 0)
    }

    func testResetClearsAllRecordedWork() {
        let counter = ChatRenderOperationCounter(isEnabled: true)
        counter.record(.reloads, by: 3)

        counter.reset()

        XCTAssertEqual(counter.snapshot()[.reloads], 0)
    }

    func testDeterministicBudgetReportsOnlyOperationsAboveTheirMaximum() {
        let counter = ChatRenderOperationCounter(isEnabled: true)
        counter.record(.rowsEnumerated, by: 81)
        counter.record(.offsetMutations)
        counter.record(.activeTasks)

        let budget = ChatRenderOperationBudget(maximums: [
            .rowsEnumerated: 80,
            .offsetMutations: 1,
            .activeTasks: 0
        ])

        XCTAssertEqual(
            budget.violations(in: counter.snapshot()),
            [
                ChatRenderOperationBudgetViolation(
                    operation: .rowsEnumerated,
                    actual: 81,
                    maximum: 80
                ),
                ChatRenderOperationBudgetViolation(
                    operation: .activeTasks,
                    actual: 1,
                    maximum: 0
                )
            ]
        )
    }

    func testDeterministicBudgetAcceptsCountsAtTheirMaximum() {
        let counter = ChatRenderOperationCounter(isEnabled: true)
        counter.record(.rowsEnumerated, by: 80)
        counter.record(.offsetMutations)

        let budget = ChatRenderOperationBudget(maximums: [
            .rowsEnumerated: 80,
            .offsetMutations: 1,
            .activeTasks: 0
        ])

        XCTAssertTrue(budget.violations(in: counter.snapshot()).isEmpty)
    }
}
