import Foundation
@testable import DisplayCore

enum Fx {
    static let samsungID = DisplayIdentity(vendor: 19501, model: 29455, serial: 900000001, alphaSerial: "TESTSERIAL01",
                                           productName: "S34CG50", manufacturer: "SAM")
    static let otherID = DisplayIdentity(vendor: 19501, model: 29455, serial: 111, alphaSerial: "OTHER0001",
                                         productName: "S34CG50", manufacturer: "SAM")
    static let builtInID = DisplayIdentity(vendor: 1552, model: 41031, serial: 9, alphaSerial: nil,
                                           productName: "Color LCD", manufacturer: nil)

    static func ext(_ uuid: String = "UUID-EXT", id: DisplayIdentity = samsungID) -> DisplayDescriptor {
        DisplayDescriptor(uuid: uuid, edidUUID: "EDID-\(uuid)", displayID: 2, identity: id, isBuiltIn: false, hasEndpoint: true)
    }
    static let builtIn = DisplayDescriptor(uuid: "UUID-BUILTIN", edidUUID: nil, displayID: 1, identity: builtInID,
                                           isBuiltIn: true, hasEndpoint: false)

    /// Fake with the built-in plus one Samsung at brightness 80/100, contrast 60/100, RGB 56/56/63.
    static func rig(_ displays: [DisplayDescriptor]? = nil) -> (FakeTransport, DisplayController) {
        let e = ext()
        let f = FakeTransport(displays: displays ?? [builtIn, e])
        for d in f.scan() where d.hasEndpoint {
            f.setValue(.init(current: 80, maximum: 100), .brightness, uuid: d.uuid)
            f.setValue(.init(current: 60, maximum: 100), .contrast, uuid: d.uuid)
            f.setValue(.init(current: 56, maximum: 100), .red, uuid: d.uuid)
            f.setValue(.init(current: 56, maximum: 100), .green, uuid: d.uuid)
            f.setValue(.init(current: 63, maximum: 100), .blue, uuid: d.uuid)
            f.setValue(.init(current: 5, maximum: 4), .colorPreset, uuid: d.uuid)      // 5 = Custom, as measured
            f.setValue(.init(current: 56, maximum: 100), .sharpness, uuid: d.uuid)
            f.setValue(.init(current: 80, maximum: 100), .volume, uuid: d.uuid)
            f.setValue(.init(current: 1, maximum: 255), Control(0xE0), uuid: d.uuid)   // unknown Samsung code
        }
        return (f, DisplayController(transport: f))
    }

    static func target(_ c: DisplayController) async throws -> DisplayTarget {
        let snap = await c.refresh()
        let d = snap.displays.first { !$0.isBuiltIn }!
        return try c.target(for: d, in: snap)
    }
}
