import AppKit
import SwiftUI
import XCTest
import WhopperKit
@testable import Whopper

final class PermissionAssistantRenderTests: XCTestCase {
    @MainActor
    func testEveryAssistantStageRendersWithoutRequestingPermissions() throws {
        for grant in [Permission.inputMonitoring, .accessibility, .systemAudio] {
            var flow = PermissionFlow(grant, repair: true)
            for stage in ["prepare", "waiting", "ready"] {
                if stage == "waiting" { flow.begin(); flow.wait() }
                if stage == "ready" { flow.finish() }
                let view = PermissionAssistantCard(flow: flow, state: stage == "ready" ? .granted : .denied,
                                                   canRepair: true)
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let cg = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(cg.width, 800)
                XCTAssertLessThan(cg.height, 1500, "Assistant should fit a normal Mac screen")
                if let folder = ProcessInfo.processInfo.environment["WHOPRRR_ASSISTANT_RENDERS"] {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent("\(grant.rawValue)-\(stage).png")
                    try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
}
