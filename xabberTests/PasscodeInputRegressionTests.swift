import XCTest
@testable import xabber

final class PasscodeInputRegressionTests: XCTestCase {
    @MainActor
    func testOnlySixASCIIDigitsCanCompletePIN() {
        let input = PasscodeEdtitView()
        var completed: [String] = []
        input.didFinishedEnterCode = { completed.append($0) }

        input.insertText("12")
        input.insertText("٣")
        input.insertText("a")
        input.insertText("3456")

        XCTAssertEqual(input.code, "123456")
        XCTAssertEqual(completed, ["123456"])
        XCTAssertEqual(input.stack.arrangedSubviews.count, 6)
    }

    @MainActor
    func testPasteBeyondRemainingCapacityIsRejectedWithoutChangingIndicators() {
        let input = PasscodeEdtitView()
        var completions = 0
        input.didFinishedEnterCode = { _ in completions += 1 }

        input.insertText("12345")
        input.insertText("67")

        XCTAssertEqual(input.code, "12345")
        XCTAssertEqual(input.stack.arrangedSubviews.count, 6)
        XCTAssertEqual(completions, 0)

        input.insertText("6")
        input.insertText("7")
        XCTAssertEqual(input.code, "123456")
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testRepeatedFullValueDoesNotCompleteTwiceUntilReset() {
        let input = PasscodeEdtitView()
        var completed: [String] = []
        input.didFinishedEnterCode = { completed.append($0) }

        input.insertText("123456")
        input.code = "123456"
        XCTAssertEqual(completed, ["123456"])

        input.code = ""
        input.insertText("123456")
        XCTAssertEqual(completed, ["123456", "123456"])
    }
}
