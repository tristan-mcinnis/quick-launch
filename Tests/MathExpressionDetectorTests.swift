import Testing
@testable import QuickLaunch

@Suite("MathExpressionDetector")
struct MathExpressionDetectorTests {

    // MARK: — Positive: pure math expressions

    @Test func testSimpleAddition() {
        #expect(MathExpressionDetector.isMathExpression("2+2") == true)
    }

    @Test func testSubtraction() {
        #expect(MathExpressionDetector.isMathExpression("10-3") == true)
    }

    @Test func testMultiplication() {
        #expect(MathExpressionDetector.isMathExpression("4*5") == true)
    }

    @Test func testDivision() {
        #expect(MathExpressionDetector.isMathExpression("10/2") == true)
    }

    @Test func testParentheses() {
        #expect(MathExpressionDetector.isMathExpression("(3+4)*2") == true)
    }

    @Test func testEuropeanDecimalComma() {
        #expect(MathExpressionDetector.isMathExpression("54,34*6") == true)
    }

    @Test func testDecimalDot() {
        #expect(MathExpressionDetector.isMathExpression("3.14*2") == true)
    }

    @Test func testComplexExpression() {
        #expect(MathExpressionDetector.isMathExpression("54,34*6-(435353)") == true)
    }

    @Test func testPower() {
        #expect(MathExpressionDetector.isMathExpression("2^10") == true)
    }

    @Test func testModulo() {
        #expect(MathExpressionDetector.isMathExpression("17%3") == true)
    }

    @Test func testUnaryMinus() {
        #expect(MathExpressionDetector.isMathExpression("-5*3") == true)
    }

    @Test func testSqrt() {
        #expect(MathExpressionDetector.isMathExpression("sqrt(16)") == true)
    }

    @Test func testSin() {
        #expect(MathExpressionDetector.isMathExpression("sin(0.5)") == true)
    }

    @Test func testCos() {
        #expect(MathExpressionDetector.isMathExpression("cos(3.14)") == true)
    }

    @Test func testTan() {
        #expect(MathExpressionDetector.isMathExpression("tan(1)") == true)
    }

    @Test func testLog() {
        #expect(MathExpressionDetector.isMathExpression("log(100)") == true)
    }

    @Test func testLn() {
        #expect(MathExpressionDetector.isMathExpression("ln(2.718)") == true)
    }

    @Test func testAbs() {
        #expect(MathExpressionDetector.isMathExpression("abs(-42)") == true)
    }

    @Test func testNestedParentheses() {
        #expect(MathExpressionDetector.isMathExpression("((2+3)*(4-1))/5") == true)
    }

    @Test func testWhitespaceAroundOperators() {
        #expect(MathExpressionDetector.isMathExpression("3 + 4") == true)
    }

    @Test func testLargeNumbers() {
        #expect(MathExpressionDetector.isMathExpression("1000000*1000000") == true)
    }

    @Test func testMixedOperators() {
        #expect(MathExpressionDetector.isMathExpression("2+3*4-1/2") == true)
    }

    @Test func testPiConstant() {
        #expect(MathExpressionDetector.isMathExpression("pi*2") == true)
    }

    @Test func testEConstant() {
        #expect(MathExpressionDetector.isMathExpression("e^2") == true)
    }

    @Test func testFloor() {
        #expect(MathExpressionDetector.isMathExpression("floor(3.7)") == true)
    }

    @Test func testCeil() {
        #expect(MathExpressionDetector.isMathExpression("ceil(3.2)") == true)
    }

    // MARK: — Negative: natural language (not math expressions)

    @Test func testPlainText() {
        #expect(MathExpressionDetector.isMathExpression("hello world") == false)
    }

    @Test func testQuestion() {
        #expect(MathExpressionDetector.isMathExpression("what is 2+2") == false)
    }

    @Test func testLongSentence() {
        #expect(MathExpressionDetector.isMathExpression("how do I cook pasta") == false)
    }

    @Test func testSingleWord() {
        #expect(MathExpressionDetector.isMathExpression("hello") == false)
    }

    @Test func testEmptyString() {
        #expect(MathExpressionDetector.isMathExpression("") == false)
    }

    @Test func testSingleDigit() {
        #expect(MathExpressionDetector.isMathExpression("5") == false)
    }

    @Test func testSingleNumber() {
        #expect(MathExpressionDetector.isMathExpression("42") == false)
    }

    @Test func testTextWithNumbers() {
        #expect(MathExpressionDetector.isMathExpression("I have 3 cats") == false)
    }

    @Test func testURLLike() {
        #expect(MathExpressionDetector.isMathExpression("https://example.com") == false)
    }

    @Test func testDateLike() {
        #expect(MathExpressionDetector.isMathExpression("April 11, 2026") == false)
    }
}
