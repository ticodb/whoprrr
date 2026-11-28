import AppKit
import SwiftUI
import XCTest
@testable import Whopper

final class SetupDrawerRenderTests: XCTestCase {
    @MainActor
    func testReadySetupFitsTheDrawerWithoutTheFullWindowRail() throws {
        let card = SetupDrawerCard(title: "Permissions are ready", detail: "Continue to use your features. Diagnostic checks are optional.",
                                   primaryTitle: "Continue", permissions: [("Accessibility", true), ("Input Monitoring", true)])
            .frame(width: 720, height: 380)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let cg = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(cg.width, 1440)
        XCTAssertEqual(cg.height, 760)
        if let path = ProcessInfo.processInfo.environment["WHOPRRR_SETUP_DRAWER_RENDER"] {
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
