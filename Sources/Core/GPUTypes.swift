// GPUTypes.swift — the CPU-side mirror of the structs the Metal fragment shader reads.
//
// These MUST stay byte-for-byte compatible with `struct Hole` and `struct Globals` in
// Rendering/Shaders.metal — same field order, same sizes/alignment. Both the full-screen
// overlay (Renderer) and the pet (PetView) fill these and hand them to the shader.

import simd

/// One black hole. Matches `struct Hole` in Shaders.metal.
struct GPUHole {
    var center: SIMD2<Float>   // uv [0,1], top-left origin
    var radius: Float          // event-horizon radius, fraction of screen height
    var lens: Float            // lensing strength (sets both depth and reach)
    var diskGain: Float        // accretion-disk brightness
    var tilt: Float            // disk tilt, radians
    var spin: Float            // disk rotation speed/direction (signed)
    var intensity: Float       // 0..1 fade (spawn/despawn/idle)
    var depth: Float           // 0 = nearest, 1 = farthest (layering / redshift)
}

/// Per-pass globals. Matches `struct Globals` in Shaders.metal (48 bytes).
struct GPUGlobals {
    var iResolution: SIMD2<Float>
    var iTime: Float
    var glow: Float            // ambient glow gain (shared)
    var holeCount: Int32
    var lensDesktop: Int32 = 1 // 1 = sample + warp the captured desktop; 0 = self-contained (clear bg)
    // The region of iChannel0 to treat as "the desktop behind this view", in normalized
    // texture coords (top-left origin). Full screen for the overlay; the pet's own on-screen
    // rect for the pet, so the little hole lenses exactly the desktop it sits on.
    var desktopOrigin: SIMD2<Float> = SIMD2<Float>(0, 0)
    var desktopSize: SIMD2<Float> = SIMD2<Float>(1, 1)
    // 0 for the full-screen overlay (covers the whole screen); 1 for the pet, where the
    // lensed-desktop warp is tapered to nothing before the small window edge so it reads
    // as a soft round lens instead of ending in a hard square.
    var edgeFade: Float = 0
    var _pad: Float = 0
}
