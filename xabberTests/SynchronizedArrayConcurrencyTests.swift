import Foundation
import XCTest
@testable import xabber

final class SynchronizedArrayConcurrencyTests: XCTestCase {
    func testRemoveAtIgnoresIndexInvalidatedByRemoval() {
        let queryIDs = SynchronizedArray<String>()
        queryIDs.append("mam-terminal-query")

        let staleIndex = queryIDs.index(where: { $0 == "mam-terminal-query" })
        XCTAssertEqual(staleIndex, 0)

        queryIDs.remove("mam-terminal-query")

        var removedQueryID: String?
        queryIDs.remove(at: staleIndex!) { removedQueryID = $0 }

        XCTAssertNil(removedQueryID)
        XCTAssertTrue(queryIDs.isEmpty)
    }

    func testSubscriptSetterIgnoresIndexInvalidatedByRemoval() {
        let queryIDs = SynchronizedArray<String>()
        queryIDs.append("mam-terminal-query")

        let staleIndex = queryIDs.index(where: { $0 == "mam-terminal-query" })
        XCTAssertEqual(staleIndex, 0)

        queryIDs.remove("mam-terminal-query")
        queryIDs[staleIndex!] = "replacement-query"

        XCTAssertTrue(queryIDs.isEmpty)
    }

    func testConcurrentRemovalOfTheSameQueryIDIsIdempotent() {
        let queryIDs = SynchronizedArray<String>()
        let queryID = "mam-terminal-query"

        for _ in 0..<100 {
            queryIDs.append(queryID)

            let ready = DispatchGroup()
            let finished = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            let queue = DispatchQueue(
                label: "SynchronizedArrayConcurrencyTests.remove",
                attributes: .concurrent
            )

            for _ in 0..<32 {
                ready.enter()
                finished.enter()
                queue.async {
                    ready.leave()
                    start.wait()
                    queryIDs.remove(queryID)
                    finished.leave()
                }
            }

            XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)
            for _ in 0..<32 {
                start.signal()
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
            XCTAssertFalse(queryIDs.contains(queryID))
            XCTAssertEqual(queryIDs.count, 0)
        }
    }
}
