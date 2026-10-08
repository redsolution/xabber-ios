import XCTest
import XMPPFramework
@testable import xabber

final class ForwardWireBodyTests: XCTestCase {
    func testEscapingIncludesSymbolsAfterNonBMPCharacter() {
        let body = "😀>&<\"'"

        let escaped = body.xmlEscaping(reverse: false)

        XCTAssertEqual(escaped, "😀&gt;&amp;&lt;&quot;&apos;")
        XCTAssertEqual(escaped.unicodeScalars.count, 26)
    }

    func testEscapingIncludesSymbolsAfterCombiningSequence() {
        let body = "e\u{301}>&"

        let escaped = body.xmlEscaping(reverse: false)

        XCTAssertEqual(escaped, "e\u{301}&gt;&amp;")
        XCTAssertEqual(escaped.unicodeScalars.count, 11)
    }

    func testReverseEscapingDecodesOnceAndIncludesTrailingEntityAfterEmoji() {
        let escaped = "😀&gt; &amp;lt;"

        let body = escaped.xmlEscaping(reverse: true)

        XCTAssertEqual(body, "😀> &lt;")
    }

    func testLiteralEntityTextRoundTripsWithoutBecomingMarkup() {
        let body = "😀 &lt; &amp; &quot;"

        let escaped = body.xmlEscaping(reverse: false)

        XCTAssertEqual(escaped, "😀 &amp;lt; &amp;amp; &amp;quot;")
        XCTAssertEqual(escaped.xmlEscaping(reverse: true), body)
    }

    func testScalarDecorationMayEndInsideDecomposedGrapheme() throws {
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='alice@example.test' to='romeo@example.test' id='decomposed'>
          <body>a\u{301}b</body>
          <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='1'>
            <bold xmlns='https://xabber.com/protocol/markup'/>
          </reference>
        </message>
        """)

        let reference = try XCTUnwrap(parseReferences(message, primary: "decomposed", jid: "alice@example.test",
            owner: "romeo@example.test").first)

        XCTAssertEqual(reference.kind, .markup)
        XCTAssertEqual(reference.begin, 0)
        XCTAssertEqual(reference.end, 1, "The scalar prefix ending before the combining mark is exactly a")
    }

    func testScalarDecorationMayBeginInsideDecomposedGrapheme() throws {
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='alice@example.test' to='romeo@example.test' id='decomposed'>
          <body>a\u{301}b</body>
          <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='1' end='3'>
            <italic xmlns='https://xabber.com/protocol/markup'/>
          </reference>
        </message>
        """)

        let reference = try XCTUnwrap(parseReferences(message, primary: "decomposed", jid: "alice@example.test",
            owner: "romeo@example.test").first)

        XCTAssertEqual(reference.kind, .markup)
        XCTAssertEqual(reference.begin, 1, "Display offset counts the scalar prefix a in UTF16")
        XCTAssertEqual(reference.end, 3)
    }

    func testScalarFallbackElisionCanRemoveBaseWithoutRemovingCombiningMark() throws {
        let reference = try DDXMLElement(xmlString: """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='1'/>
        """)

        let display = "a\u{301}b".excludeFromBody([reference], groupchat: nil)

        XCTAssertEqual(Array(display.unicodeScalars), Array("\u{301}b".unicodeScalars))
    }
}
