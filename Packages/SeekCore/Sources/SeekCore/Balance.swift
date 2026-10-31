import Foundation
import CoreFoundation

public struct BalanceConfiguration: Codable, Equatable, Sendable {
    public var endpoint: String
    public var jsonPath: String
    public var unit: String
    public var refreshMinutes: Int
    public init(endpoint: String = "", jsonPath: String = "data.balance", unit: String = "", refreshMinutes: Int = 0) {
        self.endpoint = endpoint; self.jsonPath = jsonPath; self.unit = unit
        self.refreshMinutes = refreshMinutes
    }
}

public enum BalanceJSON {
    /// Format numeric API values for display without a binary floating-point round trip.
    /// Textual balances (e.g. "unlimited") remain readable rather than becoming zero.
    public static func displayValue(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                         options: .regularExpression) != nil,
              var value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return raw }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        if rounded == 0 { rounded = 0 } // Avoid a negative zero after rounding.
        let number = NSDecimalNumber(decimal: rounded).stringValue
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        return String(parts[0]) + "." + fraction + String(repeating: "0", count: max(0, 2 - fraction.count))
    }

    /// Reuse the supplier's key only on exactly the same HTTPS origin.
    public static func endpoint(_ path: String, relativeTo base: URL) throws -> URL {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.absoluteString.hasSuffix("/") ? base : URL(string: base.absoluteString + "/")!
        guard !path.isEmpty, let url = URL(string: path, relativeTo: root)?.absoluteURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == base.host?.lowercased(),
              (parts.port ?? 443) == (base.port ?? 443), parts.user == nil, parts.password == nil,
              parts.fragment == nil else {
            throw APIError.provider("余额接口必须使用当前供应商同一域名和端口的 HTTPS 地址，可填写 /user/balance 这样的路径。")
        }
        return url
    }

    /// Supports $.data.items[0].balance and RFC 6901 /data/items/0/balance.
    public static func value(_ data: Data, path: String) throws -> String {
        var current = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components: [String]
        if raw.hasPrefix("/") {
            components = raw.dropFirst().components(separatedBy: "/").map {
                $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
        } else {
            var text = raw
            if text.hasPrefix("$") { text.removeFirst() }
            if text.hasPrefix(".") { text.removeFirst() }
            text = text.replacingOccurrences(of: "[", with: ".").replacingOccurrences(of: "]", with: "")
            components = text.isEmpty ? [] : text.components(separatedBy: ".")
        }
        for component in components {
            if let object = current as? [String: Any], let value = object[component] { current = value }
            else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) { current = array[index] }
            else { throw APIError.provider("JSON 路径不存在，请检查余额接口返回结构。") }
        }
        if let number = current as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return number.stringValue
        }
        if let text = current as? String, !text.isEmpty, text.count <= 100 { return text }
        throw APIError.provider("余额字段须为数值或简短字符串，不能是对象、数组、布尔值或 null。")
    }
}
