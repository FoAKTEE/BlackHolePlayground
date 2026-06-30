// Shaders.metal — MULTIPLE black holes, on different depth layers, lensing the
// live macOS desktop AND each other.
//
// Ported from s0xDk/ghostty-blackhole (MIT). Each hole has a depth (0 = nearest,
// 1 = farthest). Holes are uploaded sorted nearest-first and the fragment marches
// the view ray front-to-back: a nearer hole bends the apparent position of the
// holes behind it (and the desktop), and its event horizon occludes whatever is
// further away. Farther holes are cosmologically red-shifted (redder + dimmer).
//
// Lensing reach scales with the "lens" strength with no hard cutoff: a strong
// hole warps the whole screen. The pass outputs PREMULTIPLIED ALPHA and is opaque
// only where it actually changes the desktop, so the desktop shows through
// everywhere else.

#include <metal_stdlib>
using namespace metal;

// Per-hole parameters (must match GPUHole in Simulation.swift).
struct Hole {
    float2 center;     // uv [0,1], top-left origin
    float  radius;     // event-horizon radius, fraction of screen height
    float  lens;       // lensing strength (sets both depth and reach)
    float  diskGain;   // accretion-disk brightness
    float  tilt;       // disk tilt, radians
    float  spin;       // disk rotation speed/direction (signed)
    float  intensity;  // 0..1 fade (spawn/despawn/idle)
    float  depth;      // 0 = nearest, 1 = farthest (layering / redshift)
};

// Global parameters (must match GPUGlobals in Simulation.swift).
struct Globals {
    float2 iResolution;
    float  iTime;
    float  glow;       // ambient glow gain (shared)
    int    holeCount;
    int    lensDesktop; // 1 = warp the captured desktop; 0 = self-contained pet (transparent bg)
    float  _pad1;
    float  _pad2;
};

// ------------------------------------------------------------------- noise --
float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i),                  hash21(i + float2(1.0, 0.0)), f.x),
               mix(hash21(i + float2(0.0,1.0)), hash21(i + float2(1.0, 1.0)), f.x), f.y);
}
float2 mirrorUV(float2 u) {                 // GLSL-style mod, keeps samples on-screen
    float2 m = u - 2.0 * floor(u / 2.0);
    return 1.0 - abs(1.0 - m);
}
float2 rot(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}
float beaming(float2 q, float r) { return smoothstep(1.0, -1.0, q.x / max(r, 1e-5)); }
float3 diskPalette(float heat) {
    float3 cool = float3(1.00, 0.38, 0.08);
    float3 mid  = float3(1.00, 0.80, 0.45);
    float3 hot  = float3(0.85, 0.90, 1.00);
    return heat < 0.5 ? mix(cool, mid, heat * 2.0) : mix(mid, hot, heat * 2.0 - 1.0);
}
// Cosmological redshift by depth: farther holes look redder and dimmer.
float3 redshiftTint(float d) { return mix(float3(1.0), float3(1.0, 0.50, 0.28), clamp(d, 0.0, 1.0)); }
float  redshiftDim(float d)  { return mix(1.0, 0.5, clamp(d, 0.0, 1.0)); }

// ------------------------------------------------------------ fullscreen tri --
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.uv  = float2(0.5 * (p[vid].x + 1.0), 0.5 * (1.0 - p[vid].y));  // top-left origin
    return o;
}

// ------------------------------------------------------------------- image --
fragment float4 blackhole_fragment(VOut in [[stage_in]],
                                   texture2d<float> iChannel0 [[texture(0)]],
                                   sampler          samp      [[sampler(0)]],
                                   constant Globals& G        [[buffer(0)]],
                                   constant Hole*    holes     [[buffer(1)]]) {
    float2 res = G.iResolution;
    float2 uv  = in.uv;
    float aspect = res.x / res.y;
    float t = G.iTime;

    float2 P = uv * float2(aspect, 1.0);     // aspect-corrected pixel position

    float2 D = float2(0.0);                   // cumulative inward ray deflection (front-to-back)
    float  vis = 1.0;                          // visibility of everything behind the current depth
    float3 emis = float3(0.0);                 // light added on top of the desktop
    float  addLum = 0.0;                       // its scalar brightness (drives opacity)
    float  warpMag = 0.0;                      // strongest deflection (drives opacity)

    // Holes arrive sorted nearest (depth 0) -> farthest (depth 1).
    int n = min(G.holeCount, 16);
    for (int i = 0; i < n; i++) {
        Hole h = holes[i];
        if (h.intensity <= 0.001 || h.radius <= 0.0001) continue;

        float rh = h.radius;
        float2 pos = P - D;                    // apparent position, bent by nearer holes
        float2 C = h.center * float2(aspect, 1.0);
        float2 pi = pos - C;
        float ri = length(pi);

        float reach = max(0.28, h.lens * 2.6); // reach grows with lensing — no hard edge
        float farLimit = max(reach * 3.5, rh * 8.0);
        if (ri > farLimit) continue;

        float2 diri = pi / max(ri, 1e-5);
        float fo = exp(-(ri / reach) * (ri / reach));
        float m = (h.lens * h.lens / max(ri, rh * 0.6)) * fo * h.intensity;
        m = min(m, 1.5);
        warpMag = max(warpMag, m);

        float sh = smoothstep(rh, rh * 1.03, ri);      // 0 inside the horizon
        float3 tint = redshiftTint(h.depth);
        float  dim  = redshiftDim(h.depth);

        // Emissive structures (compact) — occluded by nearer holes via `vis`, red-shifted by depth.
        if (ri < rh * 8.0) {
            float3 e = float3(0.0);
            float  l = 0.0;

            // ---- accretion disk ----
            float2 pd = rot(pi, h.tilt);
            float2 q  = float2(pd.x, pd.y / 0.30);
            float rd  = length(q);
            float rin = rh * 1.45, rout = rh * 4.30;
            float band = smoothstep(rin, rin * 1.30, rd) * (1.0 - smoothstep(rout * 0.55, rout, rd));
            if (band > 0.001) {
                float ang = atan2(q.y, q.x);
                float kep = pow(rin / rd, 1.5);
                float gshift = sqrt(clamp(1.0 - rh / rd, 0.04, 1.0));     // gravitational redshift
                float swirlA = ang + rd * 22.0 - t * kep * 2.6 * gshift * h.spin;
                float streaks = vnoise(float2(rd * 70.0, swirlA * 3.0)) * 0.65
                              + vnoise(float2(rd * 24.0, swirlA * 1.5 + 7.0)) * 0.35;
                streaks = 0.35 + 0.9 * streaks * streaks;
                float dop  = beaming(q, rd);
                float emit = pow(rin / rd, 2.2);
                float heat = clamp(0.85 * dop + 0.45 * (rin / rd) - 0.15, 0.0, 1.0);
                float gain = mix(0.18, 2.4, dop * dop);
                float front = smoothstep(-0.004, 0.004, pd.y);
                float occl  = mix(sh, 1.0, front);
                float b = h.diskGain * band * streaks * emit * gain * occl * h.intensity;
                e += diskPalette(heat) * b;
                l += b;
            }

            // ---- lensed far-side halo ----
            float hx = (ri - rh * 1.75) / (rh * 0.55);
            float halo = exp(-hx * hx);
            float hdop = beaming(rot(pi, h.tilt), ri);
            float hb = halo * mix(0.06, 0.55, hdop) * sh * h.intensity;
            e += diskPalette(0.45 + 0.4 * hdop) * hb;
            l += hb;

            // ---- photon ring ----
            float rx = (ri - rh * 1.16) / (rh * 0.10);
            float ring = exp(-rx * rx);
            float rb = ring * 1.4 * sh * h.intensity;
            e += float3(1.0, 0.88, 0.70) * rb;
            l += rb;

            // ---- ambient glow ----
            float gx = ri / (rh * 3.5);
            float gl = G.glow * exp(-gx * gx) * sh * h.intensity;
            e += float3(1.0, 0.55, 0.25) * gl;
            l += gl;

            emis   += e * tint * dim * vis;
            addLum += l * dim * vis;
        }

        vis *= sh;                  // this horizon occludes everything further away
        D   += diri * m;            // and bends the ray for farther holes + the desktop
    }

    // Nothing here -> fully transparent, live desktop untouched (skip the texture fetch).
    if (warpMag <= 0.0 && addLum <= 0.0 && vis > 0.999) return float4(0.0);

    float3 term = float3(0.0);
    if (G.lensDesktop != 0) {                         // lens the captured desktop
        float2 dR = D * (1.0 + 0.035), dG = D, dB = D * (1.0 - 0.035);   // chromatic split
        float2 sR = (P - dR) / float2(aspect, 1.0);
        float2 sG = (P - dG) / float2(aspect, 1.0);
        float2 sB = (P - dB) / float2(aspect, 1.0);
        term.r = iChannel0.sample(samp, mirrorUV(sR)).r;
        term.g = iChannel0.sample(samp, mirrorUV(sG)).g;
        term.b = iChannel0.sample(samp, mirrorUV(sB)).b;
        term *= vis;                    // desktop occluded by every horizon along the ray
    }
    float3 col = term + emis;

    float darkCover = clamp(1.0 - vis, 0.0, 1.0);
    // In pet mode there's no desktop, so warp alone shouldn't paint pixels — only the
    // event-horizon shadow and the glowing disk are opaque; everywhere else stays clear.
    float warpCover = (G.lensDesktop != 0) ? smoothstep(0.0006, 0.0040, warpMag) : 0.0;
    float litCover  = clamp(addLum * 2.5, 0.0, 1.0);
    float cover = clamp(max(warpCover, max(litCover, darkCover)), 0.0, 1.0);
    return float4(col * cover, cover);   // premultiplied alpha
}
