// Renderer.swift — drives the Metal pass once per frame.
//
// Each frame: advance the simulation (positions/fades for the current motion mode),
// pack the holes into a buffer, and draw the multi-hole shader over the latest
// captured desktop frame.

import MetalKit
import CoreVideo
import QuartzCore

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private let settings: ControlSettings
    private let sim: Simulation
    private let startTime = CACurrentMediaTime()
    private var lastDraw = CACurrentMediaTime()
    private var vitality: Float = 0.5   // 0...1 activity level, smoothed

    private let lock = NSLock()
    private var latestTexture: MTLTexture?
    private var latestCVTexture: CVMetalTexture?   // retained to keep the IOSurface alive

    init(mtkView: MTKView, settings: ControlSettings, sim: Simulation) {
        self.settings = settings
        self.sim = sim
        device = mtkView.device!
        commandQueue = device.makeCommandQueue()!

        let library = Renderer.loadLibrary(device)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        desc.fragmentFunction = library.makeFunction(name: "blackhole_fragment")
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        super.init()
    }

    /// Uses a precompiled default.metallib when present (Xcode build); otherwise
    /// compiles the bundled Shaders.metal source at runtime (needs only the Metal
    /// framework, not Xcode's `metal` command-line compiler).
    static func loadLibrary(_ device: MTLDevice) -> MTLLibrary {
        if Bundle.main.url(forResource: "default", withExtension: "metallib") != nil,
           let lib = device.makeDefaultLibrary(),
           lib.makeFunction(name: "blackhole_fragment") != nil {
            return lib
        }
        guard let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Shader not found: bundle has neither default.metallib nor Shaders.metal")
        }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Shader compilation failed: \(error)")
        }
    }

    /// Called from the capture queue with each new frame.
    func update(texture: MTLTexture, retaining cvTexture: CVMetalTexture) {
        lock.lock()
        latestTexture = texture
        latestCVTexture = cvTexture
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        lock.lock()
        let texture = latestTexture
        lock.unlock()

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let now = CACurrentMediaTime()
        var dt = Float(now - lastDraw)
        lastDraw = now
        dt = max(0, min(dt, 0.1))

        let idleSecs = Float(systemIdleSeconds())

        let idleFactor: Float
        if settings.fadeWhenIdle {
            idleFactor = 1 - smoothstep(8, 30, idleSecs)
        } else {
            idleFactor = 1
        }

        // Activity 0...1: rises quickly while you're typing/working, eases down when idle.
        let activeTarget: Float = idleSecs < 2.5 ? 1.0 : 0.0
        let approach: Float = (idleSecs < 2.5 ? 0.9 : 0.4)
        vitality += (activeTarget - vitality) * min(1.0, approach * dt * 6.0)

        let holes = sim.update(settings: settings, aspect: aspect, dt: dt,
                               idleFactor: idleFactor, activity: vitality)

        if let texture, !holes.isEmpty {
            var g = GPUGlobals(iResolution: SIMD2<Float>(Float(size.width), Float(size.height)),
                               iTime: Float(now - startTime),
                               glow: Float(settings.glow),
                               holeCount: Int32(holes.count))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&g, length: MemoryLayout<GPUGlobals>.stride, index: 0)
            holes.withUnsafeBytes { raw in
                if let base = raw.baseAddress { encoder.setFragmentBytes(base, length: raw.count, index: 1) }
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
