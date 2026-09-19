import Foundation

// MARK: — Error types

enum MathCalculatorError: Error, Equatable {
    case emptyExpression
    case invalidExpression(String)
    case divisionByZero
    case unknownFunction(String)
    case unmatchedParenthesis
}

// MARK: — Public API

enum MathCalculator {

    /// Evaluates a math expression string and returns the result as a Double.
    /// Supports: +, -, *, /, ^, %, parentheses, functions (sqrt/sin/cos/tan/log/ln/abs/floor/ceil/round),
    /// constants (pi, e), European decimal comma (e.g. "3,14" == 3.14).
    static func evaluate(_ expression: String) throws -> Double {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw MathCalculatorError.emptyExpression }
        let normalized = normalizeCommas(trimmed)
        let parser = ExprParser(normalized)
        let result = try parser.parseExpression()
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw MathCalculatorError.invalidExpression(
                "Unexpected character '\(parser.current!)' at position \(parser.pos)"
            )
        }
        return result
    }

    /// Formats a Double result for display:
    /// - Whole numbers are shown without a decimal point ("4", not "4.0")
    /// - Decimals are shown with trailing zeros stripped ("2.5", not "2.50")
    static func format(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 && !value.isInfinite && !value.isNaN {
            return String(format: "%g", value)  // "4", "-7", "1e+20" for huge ints
        }
        // Up to 10 significant digits, trailing zeros stripped
        return String(format: "%.10g", value)
    }

    // MARK: — Comma normalisation

    /// A comma between digits is a thousands separator when the digit run
    /// after it is exactly three, and a European decimal comma otherwise.
    /// `1,000 + 5` is 1005, `1,234,567` is 1234567, and `1,5 + 1` is 2.5.
    private static func normalizeCommas(_ expr: String) -> String {
        var result = ""
        let chars = Array(expr)
        for (i, ch) in chars.enumerated() {
            guard ch == ",", i > 0, chars[i - 1].isNumber else {
                result.append(ch)
                continue
            }
            var trailingDigits = 0
            var j = i + 1
            while j < chars.count, chars[j].isNumber {
                trailingDigits += 1
                j += 1
            }
            guard trailingDigits > 0 else {
                result.append(ch)
                continue
            }
            // Exactly three digits is a grouped number, not a decimal comma.
            if trailingDigits != 3 { result.append(".") }
        }
        return result
    }
}

// MARK: — Recursive-descent parser

private final class ExprParser {
    let chars: [Character]
    var pos: Int = 0

    init(_ s: String) { chars = Array(s) }

    var isAtEnd: Bool { pos >= chars.count }
    var current: Character? { pos < chars.count ? chars[pos] : nil }

    func skipWhitespace() {
        while pos < chars.count && chars[pos].isWhitespace { pos += 1 }
    }

    // expr = additive
    func parseExpression() throws -> Double {
        return try parseAdditive()
    }

    // additive = multiplicative (('+' | '-') multiplicative)*
    func parseAdditive() throws -> Double {
        var left = try parseMultiplicative()
        skipWhitespace()
        while let op = current, op == "+" || op == "-" {
            pos += 1
            let right = try parseMultiplicative()
            left = op == "+" ? left + right : left - right
            skipWhitespace()
        }
        return left
    }

    // multiplicative = power (('*' | '/' | '%') power)*
    func parseMultiplicative() throws -> Double {
        var left = try parsePower()
        skipWhitespace()
        while let op = current, op == "*" || op == "/" || op == "%" {
            pos += 1
            let right = try parsePower()
            switch op {
            case "*": left *= right
            case "/":
                guard right != 0 else { throw MathCalculatorError.divisionByZero }
                left /= right
            default: // "%"
                guard right != 0 else { throw MathCalculatorError.divisionByZero }
                left = left.truncatingRemainder(dividingBy: right)
            }
            skipWhitespace()
        }
        return left
    }

    // power = unary ('^' unary)*  — right-associative via recursion
    func parsePower() throws -> Double {
        let base = try parseUnary()
        skipWhitespace()
        if current == "^" {
            pos += 1
            let exp = try parsePower()   // right-associative
            return pow(base, exp)
        }
        return base
    }

    // unary = ('-' | '+') unary | primary
    func parseUnary() throws -> Double {
        skipWhitespace()
        if current == "-" { pos += 1; return try -parseUnary() }
        if current == "+" { pos += 1; return try parseUnary() }
        return try parsePrimary()
    }

    // primary = NUMBER | CONSTANT | FUNCTION '(' expr ')' | '(' expr ')'
    func parsePrimary() throws -> Double {
        skipWhitespace()
        guard let ch = current else {
            throw MathCalculatorError.invalidExpression("Unexpected end of expression")
        }

        // Number
        if ch.isNumber || ch == "." {
            return try parseNumber()
        }

        // Parenthesised expression
        if ch == "(" {
            pos += 1
            let value = try parseExpression()
            skipWhitespace()
            guard current == ")" else { throw MathCalculatorError.unmatchedParenthesis }
            pos += 1
            return value
        }

        // Identifier: constant or function call
        if ch.isLetter {
            let ident = parseIdentifier()
            skipWhitespace()

            // Constants (no parentheses)
            switch ident {
            case "pi": return Double.pi
            case "e":  return 2.718281828459045
            default:   break
            }

            // Function call — must be followed by '('
            guard current == "(" else {
                throw MathCalculatorError.invalidExpression(
                    "Expected '(' after '\(ident)'"
                )
            }
            pos += 1
            let arg = try parseExpression()
            skipWhitespace()
            guard current == ")" else { throw MathCalculatorError.unmatchedParenthesis }
            pos += 1

            switch ident {
            case "sqrt":  return sqrt(arg)
            case "sin":   return sin(arg)
            case "cos":   return cos(arg)
            case "tan":   return tan(arg)
            case "log":   return log10(arg)
            case "ln":    return log(arg)
            case "abs":   return abs(arg)
            case "floor": return floor(arg)
            case "ceil":  return ceil(arg)
            case "round": return Foundation.round(arg)
            default:
                throw MathCalculatorError.unknownFunction(ident)
            }
        }

        throw MathCalculatorError.invalidExpression("Unexpected character '\(ch)'")
    }

    func parseNumber() throws -> Double {
        var s = ""
        while let c = current, c.isNumber || c == "." { s.append(c); pos += 1 }
        guard let v = Double(s) else {
            throw MathCalculatorError.invalidExpression("Invalid number: \(s)")
        }
        return v
    }

    func parseIdentifier() -> String {
        var s = ""
        while let c = current, c.isLetter { s.append(c); pos += 1 }
        return s
    }
}
