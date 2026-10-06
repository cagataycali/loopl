import Foundation

/// A safe arithmetic evaluator: recursive descent over a fixed grammar.
/// No NSExpression (which happily does `FUNCTION(…)` and key paths), no
/// dynamic dispatch — only numbers, + - * / % ^, parentheses, a short
/// whitelist of functions and two constants.
public struct Calculator: Sendable {
    /// Why an expression could not be evaluated; the message goes back to the model.
    public enum CalcError: LocalizedError, Equatable {
        case unexpected(String), unknownFunction(String), unknownIdentifier(String), divisionByZero, tooLong
        public var errorDescription: String? {
            switch self {
            case .unexpected(let s): "unexpected \(s)"
            case .unknownFunction(let f): "unknown function \(f)"
            case .unknownIdentifier(let i): "unknown identifier \(i)"
            case .divisionByZero: "division by zero"
            case .tooLong: "expression too long"
            }
        }
    }

    public static func evaluate(_ expression: String) throws -> Double {
        guard expression.count <= 512 else { throw CalcError.tooLong }
        var p = Parser(Array(expression.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }.map(Character.init)))
        let v = try p.expression()
        guard p.atEnd else { throw CalcError.unexpected(String(p.chars[p.i...])) }
        guard v.isFinite else { throw CalcError.divisionByZero }
        return v
    }

    /// Pretty: 1081 not 1081.0, but 3.1416 keeps decimals.
    public static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        return String(format: "%.10g", v)
    }

    struct Parser {
        let chars: [Character]
        var i = 0
        init(_ c: [Character]) { chars = c }
        var atEnd: Bool { i >= chars.count }
        var peek: Character? { atEnd ? nil : chars[i] }

        mutating func expression() throws -> Double {
            var v = try term()
            while let c = peek, c == "+" || c == "-" {
                i += 1
                let r = try term()
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() throws -> Double {
            var v = try power()
            while let c = peek, c == "*" || c == "/" || c == "%" || c == "×" || c == "÷" {
                i += 1
                let r = try power()
                switch c {
                case "*", "×": v *= r
                case "/", "÷": guard r != 0 else { throw CalcError.divisionByZero }; v /= r
                default: guard r != 0 else { throw CalcError.divisionByZero }; v = v.truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }
        mutating func power() throws -> Double {
            let base = try unary()
            if peek == "^" { i += 1; return pow(base, try power()) }  // right-assoc
            return base
        }
        mutating func unary() throws -> Double {
            if peek == "-" { i += 1; return -(try unary()) }
            if peek == "+" { i += 1; return try unary() }
            return try primary()
        }
        mutating func primary() throws -> Double {
            guard let c = peek else { throw CalcError.unexpected("end of expression") }
            if c == "(" {
                i += 1
                let v = try expression()
                guard peek == ")" else { throw CalcError.unexpected("missing )") }
                i += 1
                return v
            }
            if c.isNumber || c == "." { return try number() }
            if c.isLetter {
                let name = identifier()
                if peek == "(" {
                    i += 1
                    var args: [Double] = []
                    if peek != ")" {
                        args.append(try expression())
                        while peek == "," { i += 1; args.append(try expression()) }
                    }
                    guard peek == ")" else { throw CalcError.unexpected("missing )") }
                    i += 1
                    return try apply(name.lowercased(), args)
                }
                switch name.lowercased() {
                case "pi", "π": return .pi
                case "e": return M_E
                default: throw CalcError.unknownIdentifier(name)
                }
            }
            throw CalcError.unexpected(String(c))
        }
        mutating func number() throws -> Double {
            let start = i
            while let c = peek, c.isNumber || c == "." || c == "_" { i += 1 }
            if peek == "e" || peek == "E", i + 1 < chars.count, chars[i + 1].isNumber || chars[i + 1] == "-" {
                i += 2
                while let c = peek, c.isNumber { i += 1 }
            }
            let s = String(chars[start..<i]).replacingOccurrences(of: "_", with: "")
            guard let v = Double(s) else { throw CalcError.unexpected(s) }
            return v
        }
        mutating func identifier() -> String {
            let start = i
            while let c = peek, c.isLetter || c.isNumber || c == "_" { i += 1 }
            return String(chars[start..<i])
        }
        func apply(_ f: String, _ a: [Double]) throws -> Double {
            func one() throws -> Double { guard a.count == 1 else { throw CalcError.unexpected("\(f) takes 1 argument") }; return a[0] }
            switch f {
            case "sqrt": return sqrt(try one())
            case "abs": return abs(try one())
            case "round": return (try one()).rounded()
            case "floor": return floor(try one())
            case "ceil": return ceil(try one())
            case "sin": return sin(try one())
            case "cos": return cos(try one())
            case "tan": return tan(try one())
            case "ln": return log(try one())
            case "log", "log10": return log10(try one())
            case "log2": return log2(try one())
            case "exp": return exp(try one())
            case "pow": guard a.count == 2 else { throw CalcError.unexpected("pow takes 2 arguments") }; return pow(a[0], a[1])
            case "min": guard !a.isEmpty else { throw CalcError.unexpected("min needs arguments") }; return a.min()!
            case "max": guard !a.isEmpty else { throw CalcError.unexpected("max needs arguments") }; return a.max()!
            default: throw CalcError.unknownFunction(f)
            }
        }
    }
}
