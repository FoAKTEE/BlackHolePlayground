// PetWindow.swift — a small, draggable "pet" black hole you drop files onto.
//
// This is the file-eater. It's a tiny window (not the full-screen overlay), so the rest
// of your desktop stays fully interactive: you pick up a file on the Desktop normally and
// drag it onto the pet. Dropping sends the item to the Trash and flares the hole. The pet
// renders the same Metal black hole as the overlay and lenses the desktop right behind it
// (via the shared FrameStore), tapered to a soft round edge so it isn't a hard square.

import Cocoa
import MetalKit
import QuartzCore

/// Small Metal view that draws one black hole (lensing the desktop behind it) and
/// accepts file drops.
final class PetView: MTKView, MTKViewDelegate {
    private let settings: ControlSettings
    private let frameStore: FrameStore
    private let cmdQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let dummyTexture: MTLTexture
    private let startTime = CACurrentMediaTime()
    private var lastDraw = CACurrentMediaTime()
    private var vitality: Float = 0.6
    private var pulse: Float = 0

    /// Files were dropped on the pet (the app moves them to the Trash).
    var onDrop: (([URL]) -> Void)?

    init(frame: CGRect, device: MTLDevice, settings: ControlSettings, frameStore: FrameStore) {
        self.settings = settings
        self.frameStore = frameStore
        cmdQueue = device.makeCommandQueue()!

        let lib = Renderer.loadLibrary(device)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "fullscreen_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "blackhole_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: 1, height: 1, mipmapped: false)
        td.usage = [.shaderRead]
        dummyTexture = device.makeTexture(descriptor: td)!   // never sampled in pet mode

        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        delegate = self
        registerForDraggedTypes([.fileURL])
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Don't override mouseDown — that lets the window be dragged by its background.

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = cmdQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let now = CACurrentMediaTime()
        var dt = Float(now - lastDraw); lastDraw = now
        dt = max(0, min(dt, 0.1))

        // Grow while you work; fade the devour flare.
        let idle = Float(systemIdleSeconds())
        let target: Float = idle < 2.5 ? 1.0 : 0.0
        let approach: Float = idle < 2.5 ? 0.9 : 0.4
        vitality += (target - vitality) * min(1.0, approach * dt * 6.0)
        pulse = max(0, pulse - 2.5 * dt)

        let act = max(0, min(1, vitality))
        let actSize: Float = settings.reactToActivity ? (0.60 + 0.55 * act) : 1.0
        let actGain: Float = settings.reactToActivity ? (0.50 + 0.70 * act) : 1.0
        let flare = pulse

        // Lens the desktop directly behind the pet when a captured frame is available
        // (Screen Recording granted). Otherwise fall back to a self-contained hole on a
        // transparent background — same look the pet had before.
        let captured = frameStore.current()
        let rect = desktopSubRect()
        let lensing = (captured != nil && rect != nil)

        var hole = GPUHole(center: SIMD2<Float>(0.5, 0.5),
                           radius: 0.085 * actSize * (1 + 0.35 * flare),  // disk (~4.3x) fits the window
                           lens: 0.30,                                    // bends the small desktop patch
                           diskGain: Float(settings.diskBrightness) * actGain * (1 + 1.8 * flare),
                           tilt: Float(settings.tilt),
                           spin: Float(settings.spin),
                           intensity: 1.0,
                           depth: 0.0)

        let size = view.drawableSize
        var g = GPUGlobals(iResolution: SIMD2<Float>(Float(size.width), Float(size.height)),
                           iTime: Float(now - startTime),
                           glow: max(Float(settings.glow), 0.05),
                           holeCount: 1,
                           lensDesktop: lensing ? 1 : 0,
                           desktopOrigin: rect?.origin ?? SIMD2<Float>(0, 0),
                           desktopSize: rect?.size ?? SIMD2<Float>(1, 1),
                           edgeFade: 1)                                  // soft round edge, not a hard square

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(lensing ? captured! : dummyTexture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&g, length: MemoryLayout<GPUGlobals>.stride, index: 0)
        enc.setFragmentBytes(&hole, length: MemoryLayout<GPUHole>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// The pet window's on-screen rect as a sub-rect of the captured main display, in
    /// normalized texture coords (top-left origin) — what the shader samples as "the
    /// desktop behind me". nil if it can't be resolved (no window yet / not on the main display).
    private func desktopSubRect() -> (origin: SIMD2<Float>, size: SIMD2<Float>)? {
        guard let win = window,
              let main = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() }) else { return nil }
        let pf = win.frame                    // global screen coords, bottom-left origin
        let sf = main.frame                   // main display, origin (0,0) in the global space
        let w = Float(sf.width), h = Float(sf.height)
        guard w > 0, h > 0 else { return nil }
        let u0 = Float(pf.minX - sf.minX) / w
        let v0 = Float(sf.maxY - pf.maxY) / h     // flip to top-left origin (matches the capture)
        return (SIMD2<Float>(u0, v0), SIMD2<Float>(Float(pf.width) / w, Float(pf.height) / h))
    }

    // MARK: file drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        pulse = max(pulse, 0.6)
        return .generic
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        pulse = max(pulse, 0.6)
        return .generic
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        pulse = 1.0
        onDrop?(urls)
        return true
    }

    private func hasFiles(_ s: NSDraggingInfo) -> Bool {
        s.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true])
    }
    private func fileURLs(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

final class PetWindow: NSWindow {
    let petView: PetView

    init(device: MTLDevice, settings: ControlSettings, frameStore: FrameStore) {
        let side: CGFloat = 220
        let view = PetView(frame: NSRect(x: 0, y: 0, width: side, height: side),
                           device: device, settings: settings, frameStore: frameStore)
        petView = view

        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                   styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true                 // drag the pet anywhere
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // CRITICAL: the pet is a file DROP TARGET, and macOS does not deliver Finder
        // file drags to windows at or above the screen-saver level — so the old
        // screenSaver+1 level silently made the pet impossible to drop onto (it would
        // never even highlight). `.statusBar` keeps it above ordinary windows while
        // staying in the band that still receives drags. The full-screen overlay floats
        // above it but is click-through and mostly transparent, so a drag passes straight
        // through to the pet (verified) and the holes only occasionally graze it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = view

        if let scr = NSScreen.main {                       // start near the bottom-right
            let f = scr.visibleFrame
            setFrameOrigin(NSPoint(x: f.maxX - side - 40, y: f.minY + 40))
        }
    }

    override var canBecomeKey: Bool { true }
}
