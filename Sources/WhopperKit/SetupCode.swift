import Foundation

/// The hand-over code shared by the order page, the Mac and the TV.
public enum SetupCode {
    private static let alphabet = Set("23456789ABCDEFGHJKMNPQRSTUVWXYZ".utf8)

    public static func normalize(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        var bytes = Array(trimmed.uppercased().utf8)
        if bytes.count == 8, bytes[3] == UInt8(ascii: "-") { bytes.remove(at: 3) }
        guard bytes.count == 7, bytes.allSatisfy(alphabet.contains) else { return nil }
        bytes.insert(UInt8(ascii: "-"), at: 3)
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func fromActivationURL(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "whoprrr", parts.host?.lowercased() == "activate",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        let codes = (parts.queryItems ?? []).filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value else { return nil }
        return normalize(code)
    }
}
