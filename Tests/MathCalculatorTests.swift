import Testing
@testable import QuickLaunch

@Suite("MathCalculator")
struct MathCalculatorTests {

    // MARK: — Basic arithmetic

    @Test func testAddition() throws {
        let result = try MathCalculator.evaluate("2+2")
        #expect(result == 4.0)
    }

    @Test func testSubtraction() throws {
        let result = try MathCalculator.evaluate("10-3")
        #expect(result == 7.0)
    }

    @Test func testMultiplication() throws {
        let result = try MathCalculator.evaluate("4*5")
        #expect(result == 20.0)
    }

    @Test func testDivision() throws {
        let result = try MathCalculator.evaluate("10/2")
        #expect(result == 5.0)
    }

    @Test func testDivisionNonInteger() throws {
        let result = try MathCalculator.evaluate("1/3")
        #expect(abs(result - 0.3333333333333333) < 1e-10)
    }

    @Test func testModulo() throws {
        let result = try MathCalculator.evaluate("17%3")
        #expect(result == 2.0)
    }

    @Test func testPower() throws {
        let result = try MathCalculator.evaluate("2^10")
        #expect(result == 1024.0)
    }

    // MARK: — Operator precedence

    @Test func testPrecedenceMultiplyBeforeAdd() throws {
        let result = try MathCalculator.evaluate("2+3*4")
        #expect(result == 14.0)
    }

    @Test func testPrecedenceDivideBeforeSubtract() throws {
        let result = try MathCalculator.evaluate("10-6/2")
        #expect(result == 7.0)
    }

    @Test func testPrecedencePowerBeforeMultiply() throws {
        let result = try MathCalculator.evaluate("2*3^2")
        #expect(result == 18.0)
    }

    // MARK: — Parentheses

    @Test func testParenthesesOverridePrecedence() throws {
        let result = try MathCalculator.evaluate("(2+3)*4")
        #expect(result == 20.0)
    }

    @Test func testNestedParentheses() throws {
        let result = try MathCalculator.evaluate("((2+3)*(4-1))")
        #expect(result == 15.0)
    }

    @Test func testComplexParentheses() throws {
        let result = try MathCalculator.evaluate("(10-4)*(3+2)/2")
        #expect(result == 15.0)
    }

    // MARK: — Decimal numbers

    @Test func testDecimalDot() throws {
        let result = try MathCalculator.evaluate("3.5*2")
        #expect(result == 7.0)
    }

    @Test func testEuropeanCommaDecimal() throws {
        let result = try MathCalculator.evaluate("3,5*2")
        #expect(result == 7.0)
    }

    @Test func testComplexEuropeanDecimal() throws {
        // 54.34 * 6 - 435353
        let result = try MathCalculator.evaluate("54,34*6-(435353)")
        #expect(abs(result - (54.34 * 6 - 435353)) < 1e-6)
    }

    @Test func testGroupedThousandsAreNotDecimalCommas() throws {
        #expect(try MathCalculator.evaluate("1,000 + 5") == 1005.0)
        #expect(try MathCalculator.evaluate("1,234,567") == 1_234_567.0)
        #expect(try MathCalculator.evaluate("1,000.5") == 1000.5)
    }

    @Test func testShortDigitRunsStayDecimalCommas() throws {
        #expect(try MathCalculator.evaluate("1,5 + 1") == 2.5)
        // 1.2345 + 1 is not exactly representable, so compare the result.
        #expect(abs(try MathCalculator.evaluate("1,2345 + 1") - 2.2345) < 1e-9)
        #expect(try MathCalculator.evaluate("1.5 + 1") == 2.5)
    }

    // MARK: — Unary minus

    @Test func testUnaryMinus() throws {
        let result = try MathCalculator.evaluate("-5*3")
        #expect(result == -15.0)
    }

    @Test func testUnaryMinusInParentheses() throws {
        let result = try MathCalculator.evaluate("(-3+8)")
        #expect(result == 5.0)
    }

    @Test func testDoubleUnaryMinus() throws {
        let result = try MathCalculator.evaluate("--5")
        #expect(result == 5.0)
    }

    // MARK: — Mathematical functions

    @Test func testSqrt() throws {
        let result = try MathCalculator.evaluate("sqrt(16)")
        #expect(result == 4.0)
    }

    @Test func testSqrtFloat() throws {
        let result = try MathCalculator.evaluate("sqrt(2)")
        #expect(abs(result - 1.4142135623730951) < 1e-10)
    }

    @Test func testSin() throws {
        let result = try MathCalculator.evaluate("sin(0)")
        #expect(abs(result) < 1e-10)
    }

    @Test func testCos() throws {
        let result = try MathCalculator.evaluate("cos(0)")
        #expect(result == 1.0)
    }

    @Test func testTan() throws {
        let result = try MathCalculator.evaluate("tan(0)")
        #expect(abs(result) < 1e-10)
    }

    @Test func testLog() throws {
        let result = try MathCalculator.evaluate("log(100)")
        #expect(abs(result - 2.0) < 1e-10)
    }

    @Test func testLn() throws {
        let result = try MathCalculator.evaluate("ln(1)")
        #expect(abs(result) < 1e-10)
    }

    @Test func testAbs() throws {
        let result = try MathCalculator.evaluate("abs(-42)")
        #expect(result == 42.0)
    }

    @Test func testFloor() throws {
        let result = try MathCalculator.evaluate("floor(3.7)")
        #expect(result == 3.0)
    }

    @Test func testCeil() throws {
        let result = try MathCalculator.evaluate("ceil(3.2)")
        #expect(result == 4.0)
    }

    @Test func testRound() throws {
        let result = try MathCalculator.evaluate("round(3.5)")
        #expect(result == 4.0)
    }

    // MARK: — Constants

    @Test func testPiConstant() throws {
        let result = try MathCalculator.evaluate("pi")
        #expect(abs(result - Double.pi) < 1e-10)
    }

    @Test func testEConstant() throws {
        let result = try MathCalculator.evaluate("e")
        #expect(abs(result - 2.718281828459045) < 1e-10)
    }

    @Test func testPiInExpression() throws {
        let result = try MathCalculator.evaluate("2*pi")
        #expect(abs(result - 2 * Double.pi) < 1e-10)
    }

    // MARK: — Whitespace handling

    @Test func testWhitespaceBetweenTokens() throws {
        let result = try MathCalculator.evaluate("3 + 4")
        #expect(result == 7.0)
    }

    @Test func testLeadingTrailingWhitespace() throws {
        let result = try MathCalculator.evaluate("  2 * 3  ")
        #expect(result == 6.0)
    }

    // MARK: — Error cases

    @Test func testDivisionByZeroThrows() {
        #expect(throws: MathCalculatorError.self) {
            try MathCalculator.evaluate("1/0")
        }
    }

    @Test func testInvalidExpressionThrows() {
        #expect(throws: MathCalculatorError.self) {
            try MathCalculator.evaluate("2+*3")
        }
    }

    @Test func testEmptyExpressionThrows() {
        #expect(throws: MathCalculatorError.self) {
            try MathCalculator.evaluate("")
        }
    }

    @Test func testUnmatchedParenthesisThrows() {
        #expect(throws: MathCalculatorError.self) {
            try MathCalculator.evaluate("(2+3")
        }
    }

    // MARK: — Formatted output

    @Test func testFormatIntegerResult() {
        #expect(MathCalculator.format(4.0) == "4")
    }

    @Test func testFormatDecimalResult() {
        #expect(MathCalculator.format(3.14) == "3.14")
    }

    @Test func testFormatNegativeResult() {
        #expect(MathCalculator.format(-7.0) == "-7")
    }

    @Test func testFormatTruncatesTrailingZeros() {
        #expect(MathCalculator.format(2.50) == "2.5")
    }
}
