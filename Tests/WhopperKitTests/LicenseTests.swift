import XCTest
import CryptoKit
@testable import WhopperKit

final class LicenseTests: XCTestCase {
    let signer = Curve25519.Signing.PrivateKey()
    var pub: Data { signer.publicKey.rawRepresentation }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 24 * 60 * 60

    func b64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

    /// A pass as the server makes one. `json` overrides the payload text so tests can send exact bytes.
    func pass(dev: String = "mac-1", kind: String = "mac", mac: Bool = true, tv: Bool = false, v: Int = 1, iat: TimeInterval? = nil, exp: TimeInterval? = nil, signer s: Curve25519.Signing.PrivateKey? = nil) -> String {
        let i = Int((iat ?? now.timeIntervalSince1970 - day)), e = Int(exp ?? now.timeIntervalSince1970 + 29 * day)
        let json = #"{"v":\#(v),"kid":"9f2c4a1b7d3e5a60","dev":"\#(dev)","kind":"\#(kind)","mac":\#(mac),"tv":\#(tv),"pick":false,"iat":\#(i),"exp":\#(e)}"#
        let body = Data(json.utf8)
        return b64url(body) + "." + b64url(try! (s ?? signer).signature(for: body))
    }
    func check(_ p: String, dev: String = "mac-1") -> PassCheck { PassVerifier.check(p, deviceId: dev, publicKeyRaw: pub, now: now) }
    func isNotValid(_ c: PassCheck) -> Bool { if case .notValid = c { return true }; return false }

    func testAValidPass() {
        guard case .valid(let p) = check(pass()) else { return XCTFail("expected valid") }
        XCTAssertEqual(p.dev, "mac-1"); XCTAssertTrue(p.mac); XCTAssertFalse(p.pick)
    }

    func testEachCheckFailsOnItsOwn() {
        XCTAssertTrue(isNotValid(check("nonsense")), "one part")
        XCTAssertTrue(isNotValid(check(pass() + ".extra")), "three parts")
        XCTAssertTrue(isNotValid(check("@@@." + pass().split(separator: ".")[1])), "bad base64")
        XCTAssertTrue(isNotValid(check(pass(signer: Curve25519.Signing.PrivateKey()))), "signed by another key")
        XCTAssertTrue(isNotValid(check(pass(v: 2))), "version")
        XCTAssertTrue(isNotValid(check(pass(dev: "mac-2"))), "copied from another Mac")
        XCTAssertTrue(isNotValid(check(pass(kind: "tv", mac: true, tv: true))), "a TV pass")
        XCTAssertTrue(isNotValid(check(pass(mac: false))), "key without the Mac app")
    }

    func testThePayloadBytesAreWhatIsSigned() {
        // Same JSON content, different bytes (a space added): the signature no longer matches.
        let parts = pass().split(separator: ".")
        let original = String(data: PassVerifier.base64URL(parts[0])!, encoding: .utf8)!
        let respaced = original.replacingOccurrences(of: "{\"v\":1", with: "{ \"v\":1")
        XCTAssertTrue(isNotValid(check(b64url(Data(respaced.utf8)) + "." + parts[1])))
    }

    func testExpiryWithSlackAndTheRenewalWindow() {
        let t = now.timeIntervalSince1970
        if case .valid = check(pass(exp: t - 60)) {} else { XCTFail("a minute past is inside the slack") }
        XCTAssertEqual(check(pass(iat: t - 31 * day, exp: t - day)), .expired(try! decode(pass(iat: t - 31 * day, exp: t - day)), renewable: true))
        guard case .expired(_, let renewable) = check(pass(iat: t - 100 * day, exp: t - 61 * day)) else { return XCTFail("expected expired") }
        XCTAssertFalse(renewable)
    }
    func decode(_ p: String) throws -> LicensePass { try JSONDecoder().decode(LicensePass.self, from: PassVerifier.base64URL(p.split(separator: ".")[0])!) }

    func testRenewalIsWeeklyAndAtMostDaily() throws {
        let t = now.timeIntervalSince1970
        let fresh = try decode(pass(iat: t - 6 * day)), old = try decode(pass(iat: t - 8 * day))
        XCTAssertFalse(PassVerifier.needsRenewal(fresh, now: now, lastAttempt: nil))
        XCTAssertTrue(PassVerifier.needsRenewal(old, now: now, lastAttempt: nil))
        XCTAssertFalse(PassVerifier.needsRenewal(old, now: now, lastAttempt: now.addingTimeInterval(-3600)))
        XCTAssertTrue(PassVerifier.needsRenewal(old, now: now, lastAttempt: now.addingTimeInterval(-25 * 3600)))
    }

    func testTheProductionKeyDecodesTo32Bytes() {
        let raw = LicenseKeys.rawKey(fromSPKI: LicenseKeys.productionSPKI)
        XCTAssertEqual(raw?.count, 32)
        XCTAssertNotNil(raw.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) })
        XCTAssertNil(LicenseKeys.rawKey(fromSPKI: "not base64 at all"))
        // Round trip: a key exported the way the server does it comes back as the same 32 bytes.
        let der = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]) + pub
        let pem = "-----BEGIN PUBLIC KEY-----\n\(der.base64EncodedString())\n-----END PUBLIC KEY-----\n"
        XCTAssertEqual(LicenseKeys.rawKey(fromSPKI: Data(pem.utf8).base64EncodedString()), pub)
    }

    func testDeviceIdIsStableAndHidesTheHardwareId() {
        let a = DeviceID.derive(platformUUID: "00000000-1111-2222-3333-444444444444")
        XCTAssertEqual(a, DeviceID.derive(platformUUID: "00000000-1111-2222-3333-444444444444"))
        XCTAssertNotEqual(a, DeviceID.derive(platformUUID: "00000000-1111-2222-3333-444444444445"))
        XCTAssertEqual(a.count, 64); XCTAssertFalse(a.contains("1111"))
    }

    func j(_ s: String) -> Data { Data(s.utf8) }

    func testActivateAnswers() {
        XCTAssertEqual(LicenseReplies.activate(status: 200, body: j(#"{"pass":"a.b","slot":2,"of":3,"expiresAt":"x"}"#)), .activated(pass: "a.b", slot: 2, of: 3))
        for (status, code) in [(404, "invalid_key"), (403, "not_owned"), (403, "disabled"), (403, "full"), (429, "rate_limited"), (400, "bad_request")] {
            XCTAssertEqual(LicenseReplies.activate(status: status, body: j(#"{"error":"\#(code)","message":"Server words."}"#)), .refused(code: code, message: "Server words."), code)
        }
        // A code without a message still gets plain words.
        guard case .refused("full", let m) = LicenseReplies.activate(status: 403, body: j(#"{"error":"full"}"#)) else { return XCTFail() }
        XCTAssertTrue(m.contains("downloads page"))
        for status in [503, 500, 502] { XCTAssertEqual(LicenseReplies.activate(status: status, body: j(#"{"error":"unavailable","message":"Later."}"#)), .tryLater) }
        XCTAssertEqual(LicenseReplies.activate(status: nil, body: nil), .tryLater)
        XCTAssertEqual(LicenseReplies.activate(status: 200, body: j("<html>")), .tryLater)
    }

    func testRenewAnswersNeverDropAPassOnTrouble() {
        XCTAssertEqual(LicenseReplies.renew(status: 200, body: j(#"{"pass":"n.s","expiresAt":"x"}"#)), .renewed(pass: "n.s"))
        XCTAssertEqual(LicenseReplies.renew(status: 403, body: j(#"{"error":"revoked","message":"Removed."}"#)), .revoked(message: "Removed."))
        XCTAssertEqual(LicenseReplies.renew(status: 400, body: j(#"{"error":"invalid_pass","message":"Not ours."}"#)), .revoked(message: "Not ours."))
        for (status, body) in [(503, #"{"error":"unavailable"}"#), (500, ""), (400, #"{"error":"bad_request"}"#), (403, "<html>blocked</html>"), (429, #"{"error":"rate_limited"}"#)] {
            XCTAssertEqual(LicenseReplies.renew(status: status, body: j(body)), .tryLater, "\(status)")
        }
        XCTAssertEqual(LicenseReplies.renew(status: nil, body: nil), .tryLater)
    }
}
