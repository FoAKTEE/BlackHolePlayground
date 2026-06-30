// Simulation.swift — shared control state + the CPU-side hole dynamics.
//
// ControlSettings is the single source of truth the SwiftUI panel writes to and
// the renderer reads from (both on the main thread). Simulation turns those
// settings into the per-frame array of holes the shader draws, running whatever
// motion mode is selected.

import Foundation
import Combine

// MARK: - Shared state

enum MotionMode: Int, CaseIterable, Identifiable, Hashable {
    case still, drift, orbit, gravity
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .still:   return "Still"
        case .drift:   return "Drift"
        case .orbit:   return "Orbit"
        case .gravity: return "Gravity"
        }
    }
}

final class ControlSettings: ObservableObject {
    @Published var count: Int = 3              // number of black holes (1...8)
    @Published var size: Double = 0.06         // base event-horizon radius (fraction of height)
    @Published var sizeVariation: Double = 0.4 // 0 = identical, 1 = wide spread
    @Published var lensing: Double = 0.26      // Einstein radius (how far the desktop bends)
    @Published var diskBrightness: Double = 1.0
    @Published var tilt: Double = 0.5          // disk tilt, radians
    @Published var spin: Double = 1.0          // disk rotation speed/direction
    @Published var glow: Double = 0.03         // ambient glow gain
    @Published var motion: MotionMode = .drift
    @Published var speed: Double = 1.0         // overall motion rate
    @Published var fadeWhenIdle: Bool = false  // fade everything when you stop using the Mac
    @Published var clickToPop: Bool = false    // click a hole to collapse it
    @Published var devourFiles: Bool = false   // (unused now — file eating moved to the pet window)
    @Published var showPet: Bool = false       // show the small draggable file-eating pet
    @Published var reactToActivity: Bool = true // grow brighter while you're actively working
    @Published var resetToken: Int = 0         // bump to re-scatter positions
}

// MARK: - GPU layout (must match the Metal structs in Shaders.metal)

struct GPUHole {
    var center: SIMD2<Float>
    var radius: Float
    var lens: Float
    var diskGain: Float
    var tilt: Float
    var spin: Float
    var intensity: Float
    var depth: Float
}

struct GPUGlobals {
    var iResolution: SIMD2<Float>
    var iTime: Float
    var glow: Float
    var holeCount: Int32
    var lensDesktop: Int32 = 1
    var _pad1: Float = 0
    var _pad2: Float = 0
}

// MARK: - Helpers

@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
@inline(__always) private func dot2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.x + a.y * b.y }
@inline(__always) private func len2(_ a: SIMD2<Float>) -> Float { (a.x * a.x + a.y * a.y).squareRoot() }
@inline(__always) private func fcos(_ x: Float) -> Float { Float(cos(Double(x))) }
@inline(__always) private func fsin(_ x: Float) -> Float { Float(sin(Double(x))) }

// MARK: - Simulation

final class Simulation {
    private struct Body {
        var pos: SIMD2<Float>      // aspect space: x in [0, aspect], y in [0, 1]
        var vel: SIMD2<Float>
        var radiusFactor: Float    // per-hole size multiplier
        var tiltJitter: Float      // per-hole tilt offset
        var orbitR: Float
        var orbitAngle: Float
        var orbitDir: Float        // +1 / -1
        var depth: Float           // 0 = nearest, 1 = farthest (layer / redshift)
        var intensity: Float       // current fade level
        var target: Float          // 1 = alive, 0 = dying
        var pulse: Float           // 0..1 transient flare (drag-hover / devour)
    }

    private var bodies: [Body] = []
    private var aspect: Float = 16.0 / 9.0
    private let margin: Float = 0.07
    private var didInit = false
    private var lastResetToken = Int.min
    private var lastSpread: Float = -1

    /// Advance the sim and return the holes to draw this frame.
    /// `activity` (0...1) is how actively the user is working right now.
    func update(settings s: ControlSettings, aspect: Float, dt: Float,
                idleFactor: Float, activity: Float) -> [GPUHole] {
        self.aspect = aspect
        reconcile(s)
        step(s, dt: dt)

        let base = Float(s.size)
        let baseLens = Float(s.lensing)
        let tilt = Float(s.tilt)
        let spin = Float(s.spin)

        // "Grow while you work": scale size + disk brightness with current activity.
        let act = max(0, min(1, activity))
        let actSize: Float  = s.reactToActivity ? (0.55 + 0.65 * act) : 1.0
        let actGain: Float  = s.reactToActivity ? (0.45 + 0.85 * act) : 1.0
        let gain = Float(s.diskBrightness) * actGain

        var out: [GPUHole] = []
        out.reserveCapacity(bodies.count)
        for b in bodies where b.intensity > 0.001 {
            let inten = max(0, b.intensity) * idleFactor
            let grow = inten                                   // grow in / collapse out
            let flare = b.pulse                                // 0..1 devour/hover flash
            out.append(GPUHole(
                center: SIMD2<Float>(b.pos.x / aspect, b.pos.y),   // aspect space -> uv
                radius: base * b.radiusFactor * grow * actSize * (1 + 0.6 * flare),
                lens: baseLens * grow * (1 + 0.4 * flare),         // lensing uniform; flare adds reach
                diskGain: gain * (1 + 1.8 * flare),                // bright flash on devour
                tilt: tilt + b.tiltJitter,
                spin: spin * b.orbitDir,
                intensity: inten,
                depth: b.depth))
        }
        out.sort { $0.depth < $1.depth }   // nearest first, so the shader can lens back-to-front
        return out
    }

    /// Flare the live hole nearest a point (normalized uv). Used while a file is dragged
    /// over (gentle, sustained) and on drop (strong). Returns true if one was found.
    @discardableResult
    func flareNearest(uvX: Float, uvY: Float, base: Float, aspect: Float, amount: Float) -> Bool {
        let p = SIMD2<Float>(uvX * aspect, uvY)
        var best = -1
        var bestD = Float.greatestFiniteMagnitude
        for i in bodies.indices where bodies[i].target > 0.5 {
            let d = len2(bodies[i].pos - p)
            let hitR = max(base * bodies[i].radiusFactor * 4.0, 0.10)   // generous catch radius
            if d < hitR && d < bestD { bestD = d; best = i }
        }
        if best >= 0 { bodies[best].pulse = max(bodies[best].pulse, amount); return true }
        return false
    }

    /// Collapse the live hole nearest a click (normalized uv, top-left origin).
    /// Returns true if one was hit. The caller should also lower the count so the
    /// reconcile pass doesn't immediately respawn it.
    func popNearest(uvX: Float, uvY: Float, base: Float, aspect: Float) -> Bool {
        let p = SIMD2<Float>(uvX * aspect, uvY)
        var best = -1
        var bestD = Float.greatestFiniteMagnitude
        for i in bodies.indices where bodies[i].target > 0.5 {
            let d = len2(bodies[i].pos - p)
            let hitR = max(base * bodies[i].radiusFactor * 2.5, 0.06)   // generous, easy to hit
            if d < hitR && d < bestD { bestD = d; best = i }
        }
        if best >= 0 { bodies[best].target = 0; return true }
        return false
    }

    // MARK: reconcile count / spread / reset

    private func reconcile(_ s: ControlSettings) {
        let spread = Float(s.sizeVariation)

        if !didInit {
            for _ in 0..<s.count { bodies.append(makeBody(spread: spread)) }
            layoutAll(spread: spread)
            for i in bodies.indices { bodies[i].intensity = 1 }   // visible immediately
            didInit = true
            lastResetToken = s.resetToken
            lastSpread = spread
            return
        }

        if abs(spread - lastSpread) > 0.0001 {
            for i in bodies.indices { bodies[i].radiusFactor = randFactor(spread) }
            lastSpread = spread
        }

        if s.resetToken != lastResetToken {
            lastResetToken = s.resetToken
            layoutAll(spread: spread)
        }

        let live = bodies.indices.filter { bodies[$0].target > 0.5 }
        if live.count < s.count {
            for _ in 0..<(s.count - live.count) { bodies.append(makeBody(spread: spread)) }
        } else if live.count > s.count {
            for idx in live.suffix(live.count - s.count) { bodies[idx].target = 0 }  // fade out
        }
    }

    // MARK: per-frame motion

    private func step(_ s: ControlSettings, dt: Float) {
        let sp = Float(s.speed)

        // fade toward target, drop fully-faded dying bodies
        let rate: Float = 4.0
        for i in bodies.indices {
            if bodies[i].intensity < bodies[i].target {
                bodies[i].intensity = min(bodies[i].target, bodies[i].intensity + rate * dt)
            } else if bodies[i].intensity > bodies[i].target {
                bodies[i].intensity = max(bodies[i].target, bodies[i].intensity - rate * dt)
            }
            bodies[i].pulse = max(0, bodies[i].pulse - 2.5 * dt)   // flare fades in ~0.4s
        }
        bodies.removeAll { $0.target < 0.5 && $0.intensity <= 0.002 }

        switch s.motion {
        case .still:
            break

        case .drift:
            for i in bodies.indices {
                var p = bodies[i].pos + bodies[i].vel * (sp * dt)
                bounce(&p, &bodies[i].vel)
                bodies[i].pos = p
            }

        case .orbit:
            let c = SIMD2<Float>(aspect / 2, 0.5)
            for i in bodies.indices {
                bodies[i].orbitAngle += bodies[i].orbitDir * (sp * 0.4 * dt)
                let a = bodies[i].orbitAngle, r = bodies[i].orbitR
                bodies[i].pos = SIMD2<Float>(c.x + fcos(a) * r, c.y + fsin(a) * r * 0.8)
            }

        case .gravity:
            nbody(dt: dt, sp: sp)
        }
    }

    private func nbody(dt: Float, sp: Float) {
        let G: Float = 0.06
        let eps2: Float = 0.02
        let c = SIMD2<Float>(aspect / 2, 0.5)
        var acc = [SIMD2<Float>](repeating: .zero, count: bodies.count)

        for i in bodies.indices {
            var a = SIMD2<Float>.zero
            for j in bodies.indices where j != i {
                let d = bodies[j].pos - bodies[i].pos
                let r2 = dot2(d, d) + eps2
                let inv = 1 / (r2 * r2.squareRoot())            // 1 / r^3 (softened)
                a += d * (G * bodies[j].radiusFactor * inv)
            }
            a += (c - bodies[i].pos) * 0.10                     // gentle pull to center
            acc[i] = a
        }

        let vmax: Float = 1.2
        for i in bodies.indices {
            bodies[i].vel += acc[i] * (sp * dt)
            let v = bodies[i].vel
            let speed = len2(v)
            if speed > vmax { bodies[i].vel = v * (vmax / speed) }
            bodies[i].vel *= (1 - 0.02 * dt)                    // mild damping
            var p = bodies[i].pos + bodies[i].vel * (sp * dt)
            bounce(&p, &bodies[i].vel)
            bodies[i].pos = p
        }
    }

    // MARK: spawn / layout / utilities

    private func makeBody(spread: Float) -> Body {
        Body(pos: randomPos(),
             vel: SIMD2<Float>(Float.random(in: -0.15...0.15), Float.random(in: -0.15...0.15)),
             radiusFactor: randFactor(spread),
             tiltJitter: Float.random(in: -0.4...0.4),
             orbitR: 0, orbitAngle: 0,
             orbitDir: Bool.random() ? 1 : -1,
             depth: Float.random(in: 0...1),     // its own layer
             intensity: 0, target: 1,            // fade in
             pulse: 0)
    }

    private func layoutAll(spread: Float) {
        let live = bodies.indices.filter { bodies[$0].target > 0.5 }
        let c = SIMD2<Float>(aspect / 2, 0.5)
        let R = min(aspect, 1) * 0.30
        for (k, idx) in live.enumerated() {
            let ang = (Float(k) / Float(max(live.count, 1))) * 2 * .pi + Float.random(in: -0.15...0.15)
            let r = R * Float.random(in: 0.7...1.0)
            bodies[idx].pos = clampToBox(SIMD2<Float>(c.x + fcos(ang) * r, c.y + fsin(ang) * r * 0.8))
            bodies[idx].orbitR = r
            bodies[idx].orbitAngle = ang
            bodies[idx].radiusFactor = randFactor(spread)
            bodies[idx].depth = (Float(k) + Float.random(in: 0.0...0.6)) / Float(max(live.count, 1))
            let tang = SIMD2<Float>(-fsin(ang), fcos(ang))
            bodies[idx].vel = tang * (Float.random(in: 0.05...0.14) * bodies[idx].orbitDir)
        }
        lastSpread = spread
    }

    private func randFactor(_ spread: Float) -> Float {
        max(0.3, 1 + spread * Float.random(in: -1...1))
    }
    private func randomPos() -> SIMD2<Float> {
        SIMD2<Float>(Float.random(in: margin...(aspect - margin)),
                     Float.random(in: margin...(1 - margin)))
    }
    private func clampToBox(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(min(max(p.x, margin), aspect - margin),
                     min(max(p.y, margin), 1 - margin))
    }
    private func bounce(_ p: inout SIMD2<Float>, _ v: inout SIMD2<Float>) {
        let hiX = aspect - margin, hiY = 1 - margin
        if p.x < margin { p.x = margin; v.x =  abs(v.x) }
        if p.x > hiX    { p.x = hiX;    v.x = -abs(v.x) }
        if p.y < margin { p.y = margin; v.y =  abs(v.y) }
        if p.y > hiY    { p.y = hiY;    v.y = -abs(v.y) }
    }
}
