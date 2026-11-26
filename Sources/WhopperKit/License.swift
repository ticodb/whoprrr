import Foundation
import CryptoKit

// The licence check, as plain logic with no network and no storage, so every rule is unit-tested.
// Contract: docs/licensing.md in the whoprrr.app site repository. A device holds a "pass": a small token the server signed
// for this device only, valid 30 days and renewed quietly. The app verifies it offline on every launch.

/// What a pass says. It never contains the key.
public struct LicensePass: Codable, Equatable, Sendable {
    public var v: Int
    public var kid: String
    public var dev: String
    public var kind: String
    public var mac: Bool
    public var tv: Bool
    public var pick: Bool
    public var iat: Int
    public var exp: Int

    public var issued: Date { Date(timeIntervalSince1970: TimeInterval(iat)) }
    public var expires: Date { Date(timeIntervalSince1970: TimeInterval(exp)) }
}

public enum PassCheck: Equatable, Sendable {
    case valid(LicensePass)
    /// The signature and device are right but the date has passed. `renewable`: the server still accepts it for renewal (60 days).
    case expired(LicensePass, renewable: Bool)
    /// Not a pass for this app on this Mac: damaged, signed by someone else, or copied from another device.
    case notValid(String)
}

public enum LicenseKeys {
    /// The public key passes are checked against: the value `GET https://whoprrr.app/api/pass-key` returns as `spki`
    /// (base64 of the SPKI PEM of an Ed25519 key). Public; replacing it is the only change needed if the server's key changes.
    public static let productionSPKI = "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUNvd0JRWURLMlZ3QXlFQTZiQzkzYm9aSDl0akc1enY5bUVmMTY1eHNQckx4WlMxNjdpUzJVMiswRTA9Ci0tLS0tRU5EIFBVQkxJQyBLRVktLS0tLQo="

    /// The 32 raw key bytes from that form: base64 → PEM → strip the BEGIN/END lines → base64 → DER → last 32 bytes.
    public static func rawKey(fromSPKI spki: String) -> Data? {
        guard let pemData = Data(base64Encoded: spki.trimmingCharacters(in: .whitespacesAndNewlines)), let pem = String(data: pemData, encoding: .utf8) else { return nil }
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), der.count >= 32 else { return nil }
        return der.suffix(32)
    }
}

public enum PassVerifier {
    public static let slack: TimeInterval = 120
    public static let renewableFor: TimeInterval = 60 * 24 * 60 * 60

    static func base64URL(_ s: Substring) -> Data? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// The six checks, in order: two parts; signature over the decoded payload bytes; version; this device; this app; date.
    public static func check(_ pass: String, deviceId: String, kind: String = "mac", publicKeyRaw: Data, now: Date = Date()) -> PassCheck {
        let parts = pass.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let body = base64URL(parts[0]), let sig = base64URL(parts[1]) else { return .notValid("not a pass") }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw), key.isValidSignature(sig, for: body) else { return .notValid("signature") }
        guard let p = try? JSONDecoder().decode(LicensePass.self, from: body) else { return .notValid("unreadable") }
        guard p.v == 1 else { return .notValid("version") }
        guard p.dev == deviceId else { return .notValid("another device") }
        guard p.kind == kind, kind == "mac" ? p.mac : p.tv else { return .notValid("another app") }
        let t = now.timeIntervalSince1970
        if TimeInterval(p.exp) > t - slack { return .valid(p) }
        return .expired(p, renewable: t - TimeInterval(p.exp) <= renewableFor)
    }

    /// Renew once the pass is over 7 days old, and not more than once a day.
    public static func needsRenewal(_ p: LicensePass, now: Date = Date(), lastAttempt: Date?) -> Bool {
        guard now.timeIntervalSince(p.issued) > 7 * 24 * 60 * 60 else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 24 * 60 * 60 { return false }
        return true
    }
}

/// A stable id for this Mac that reveals nothing: a keyed hash of the hardware UUID. It survives a reinstall, so a reinstalled
/// app does not use up a second place on the key.
public enum DeviceID {
    static let salt = "gg.tico.whoprrr.device.v1"
    public static func derive(platformUUID: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(platformUUID.utf8), using: SymmetricKey(data: Data(salt.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Server answers

public enum ActivateOutcome: Equatable, Sendable {
    case activated(pass: String, slot: Int?, of: Int?)
    /// The server said no. `code` is its error code (invalid_key, not_owned, disabled, full, rate_limited, bad_request);
    /// `message` is written for the person and shown as it is.
    case refused(code: String, message: String)
    /// Nothing wrong with the key; the server could not answer. Try again later.
    case tryLater
}

public enum RenewOutcome: Equatable, Sendable {
    case renewed(pass: String)
    /// This Mac is no longer allowed: removed from the key, the key was switched off, or the pass is too old. Drop the pass.
    case revoked(message: String)
    /// Keep the current pass and try again at the next check.
    case tryLater
}

public enum LicenseReplies {
    struct Body: Decodable { var pass: String?; var slot: Int?; var of: Int?; var error: String?; var message: String? }
    static func parse(_ data: Data?) -> Body? { data.flatMap { try? JSONDecoder().decode(Body.self, from: $0) } }

    /// Fallback wording when the server sent a code without a message. Plain words: these are key screens.
    public static func fallback(_ code: String) -> String {
        switch code {
        case "invalid_key": "That key was not recognised. Check it and try again."
        case "not_owned": "This key does not include Whoprrr for Mac."
        case "disabled": "This key has been switched off. Write to hello@whoprrr.app."
        case "full": "All the places on this key are in use. Open your personal downloads page (the link in your receipt email) to remove a device you no longer use."
        case "rate_limited": "Too many tries. Wait a while and try again."
        default: "The key could not be checked. Try again."
        }
    }

    /// `status` nil means the request never got an answer (offline, timeout).
    public static func activate(status: Int?, body: Data?) -> ActivateOutcome {
        guard let status else { return .tryLater }
        let b = parse(body)
        if status == 200, let pass = b?.pass, !pass.isEmpty { return .activated(pass: pass, slot: b?.slot, of: b?.of) }
        if [400, 403, 404, 429].contains(status), let code = b?.error { return .refused(code: code, message: (b?.message).flatMap { $0.isEmpty ? nil : $0 } ?? fallback(code)) }
        return .tryLater
    }

    public static func renew(status: Int?, body: Data?) -> RenewOutcome {
        guard let status else { return .tryLater }
        let b = parse(body)
        if status == 200, let pass = b?.pass, !pass.isEmpty { return .renewed(pass: pass) }
        if (status == 403 && b?.error == "revoked") || (status == 400 && b?.error == "invalid_pass") {
            return .revoked(message: (b?.message).flatMap { $0.isEmpty ? nil : $0 } ?? "This Mac is no longer activated on that key. Enter your key to activate it again.")
        }
        return .tryLater       // network trouble, 5xx, or a malformed request: never a reason to drop a pass
    }
}

/// What the app shows and allows.
public enum LicenseState: Equatable, Sendable {
    /// No usable pass. `message`: why, when there is something to say (the server's own words after a removal).
    case needsKey(message: String?)
    case licensed(LicensePass)
    /// The pass ran out and the server could not be reached to refresh it. Kept, not deleted.
    case expiredOffline(LicensePass)

    public var isLicensed: Bool { if case .licensed = self { return true }; return false }
}
