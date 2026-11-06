import Foundation
import HeftCore
import Testing

@Suite("Replacements around prices")
struct ReplacementPriceTests {
    @Test("A dollar before a space opens no math, so later text is still prose")
    func priceIsNotMath() {
        let line = "- Paid 5$ plan, e.g. for mails, higher limits ->" as NSString
        #expect(SmartTypography.allowsSubstitution(in: line, at: line.length))
    }

    @Test("Inside inline math nothing is replaced")
    func mathStaysMath() {
        let line = "Where $a ->" as NSString
        #expect(!SmartTypography.allowsSubstitution(in: line, at: line.length))
        let closed = "Where $a$ and ->" as NSString
        #expect(SmartTypography.allowsSubstitution(in: closed, at: closed.length))
    }
}
