import AVFoundation
import AppKit
import CoreImage
import DisplayCore

enum CameraError: Error, CustomStringConvertible {
    case denied, noDevice, noFrames
    var description: String {
        switch self {
        case .denied: return "Camera access is off. Enable it in System Settings → Privacy & Security → Camera."
        case .noDevice: return "No camera found. For an iPhone: unlock it, keep it near the Mac, and turn on Continuity Camera."
        case .noFrames: return "The camera is not delivering frames."
        }
    }
}

/// Any camera that can see both screens: iPhone via Continuity Camera, a webcam, or the built-in camera.
/// Frames are copied out as 8-bit BGRA for DisplayCore's analyzer.
final class CameraSource: NSObject, ObservableObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published var selectedID: String?
    @Published private(set) var preview: CGImage?
    @Published private(set) var running = false

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.frames")
    private let lock = NSLock()
    private var latest: (frame: Frame, time: Date)?
    private var wantPreview = false
    private var frameCount = 0
    private let ciContext = CIContext()

    override init() {
        super.init()
        refreshDevices()
    }

    func refreshDevices() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
                                                    mediaType: .video, position: .unspecified).devices
        // iPhone first (best sensor, usually mounted facing the desk), then other cameras.
        devices = found.sorted { ($0.isContinuityCamera ? 0 : 1, $0.localizedName) < ($1.isContinuityCamera ? 0 : 1, $1.localizedName) }
        if selectedID == nil || !devices.contains(where: { $0.uniqueID == selectedID }) {
            selectedID = devices.first(where: { !$0.localizedName.lowercased().contains("virtual") })?.uniqueID ?? devices.first?.uniqueID
        }
    }

    func start(preview: Bool) async throws {
        wantPreview = preview
        if running { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.denied }
        default: throw CameraError.denied
        }
        refreshDevices()
        guard let dev = devices.first(where: { $0.uniqueID == selectedID }),
              let input = try? AVCaptureDeviceInput(device: dev) else { throw CameraError.noDevice }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        if session.canAddInput(input) { session.addInput(input) }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        await MainActor.run { running = true }
    }

    func stop() {
        session.stopRunning()
        lock.withLock { latest = nil }
        DispatchQueue.main.async { self.running = false; self.preview = nil }
    }

    func setPreview(_ on: Bool) { wantPreview = on; if !on { DispatchQueue.main.async { self.preview = nil } } }

    /// A frame captured after this call (so a patch change has reached the sensor).
    func frame() async throws -> Frame {
        let asked = Date()
        for _ in 0..<60 {
            if let l = lock.withLock({ latest }), l.time >= asked { return l.frame }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CameraError.noFrames
    }

    // MARK: Sample buffers

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let data = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bpr * h))
        lock.withLock { latest = (Frame(width: w, height: h, bytesPerRow: bpr, bgra: data), Date()) }

        frameCount += 1
        if wantPreview, frameCount % 4 == 0 {
            let ci = CIImage(cvPixelBuffer: pb)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) { DispatchQueue.main.async { self.preview = cg } }
        }
    }
}
