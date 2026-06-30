// ScreenCaptureManager.swift — the live screen feed.
//
// THE important bit: the SCContentFilter excludes our own application, so the
// transparent overlay we draw is never captured and re-lensed. Without that you
// get an infinite mirror (the hole eating its own reflection).

import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Metal

final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let device: MTLDevice
    private let onFrame: (MTLTexture, CVMetalTexture) -> Void
    private let queue = DispatchQueue(label: "blackhole.capture")
    private var stream: SCStream?
    private var textureCache: CVMetalTextureCache?

    init(displayID: CGDirectDisplayID,
         device: MTLDevice,
         onFrame: @escaping (MTLTexture, CVMetalTexture) -> Void) {
        self.displayID = displayID
        self.device = device
        self.onFrame = onFrame
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "blackhole", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "display not found"])
        }

        // Exclude our own app's windows (i.e. the overlay) from the capture.
        let me = content.applications.first { $0.processID == getpid() }
        let filter = SCContentFilter(display: scDisplay,
                                     excludingApplications: me.map { [$0] } ?? [],
                                     exceptingWindows: [])

        let scale = NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2.0
        let cfg = SCStreamConfiguration()
        cfg.width  = Int(CGFloat(scDisplay.width)  * scale)
        cfg.height = Int(CGFloat(scDisplay.height) * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 5
        cfg.showsCursor = false                 // the real cursor draws on top anyway
        cfg.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let cache = textureCache,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Drop frames the system flags as incomplete (idle/blank); tolerate parse misses.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &cvTexture)
        guard result == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        // Hand off both: the renderer retains cvTexture so the IOSurface stays alive
        // until the GPU is done sampling it.
        onFrame(texture, cvTexture)
        CVMetalTextureCacheFlush(cache, 0)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("capture stopped: \(error)")
    }
}
