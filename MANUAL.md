# BlackHolePlayground — manual

The full reference. For a 30‑second start, see the [README](README.md).

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install & first launch](#install--first-launch)
- [Build options](#build-options)
- [Shortcuts](#shortcuts)
- [Controls](#controls)
- [The file-eating pet](#the-file-eating-pet)
- [Project layout](#project-layout)
- [Known caveats](#known-caveats)
- [Ideas / next steps](#ideas--next-steps)
- [Credit & license](#credit--license)

## How it works

Multiple black holes float over your **real** desktop, each on its own depth layer: a
nearer hole bends the apparent position of the ones behind it, and farther holes are
cosmologically red‑shifted (redder and dimmer). It began as the
[s0xDk/ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole) shader (MIT),
extended here to N depth‑sorted holes traced front‑to‑back, moved by a small CPU
simulation and driven by a SwiftUI panel.

```
ScreenCaptureKit  ──frames──▶  Metal texture  ──▶  black-hole fragment shader
   (your app EXCLUDED                                        │
    from the capture)                                        ▼
                                          transparent, click-through overlay window
                                          (premultiplied alpha; opaque only where
                                           the hole actually distorts the desktop)
```

Three decisions carry the whole port:

1. **Self-exclusion to avoid the feedback loop.** The capture filter (`SCContentFilter`)
   excludes this app's own windows, so the overlay we draw is never captured and
   re‑lensed. Without it you get an infinite mirror.
2. **Coverage-follows-effect alpha.** The shader outputs premultiplied alpha that is
   opaque only over the warp, disk, ring, glow, and shadow interior, and fully transparent
   everywhere else. The captured/real seam therefore lands exactly where the effect fades
   to zero, so it's invisible — and the live desktop stays interactive everywhere outside
   the hole.
3. **Depth-layered, front-to-back lensing.** Each hole has a depth; the holes are uploaded
   sorted nearest‑first and the fragment shader marches the view ray through them front to
   back. A nearer hole bends the apparent position of the holes behind it (and the
   desktop), and its event horizon occludes whatever is deeper, while farther holes are
   red‑shifted. The desktop sample still receives the *combined* deflection, so strong
   lensing warps the whole screen. Positions come from a tiny CPU n‑body/orbit/drift
   simulation (`Core/Simulation.swift`).

The shader stays cheap by skipping any hole whose influence doesn't reach the current
pixel, and by computing the expensive disk/ring/glow only right around each hole — so cost
tracks holes *near* a pixel, not the total count.

## Requirements

- macOS 13+ (14+ recommended), Apple Silicon or Intel.
- Xcode Command Line Tools (`xcode-select --install`).
- **Screen Recording** permission (granted on first launch). The file‑eating pet works
  without it; only the desktop lensing needs it.

## Install & first launch

The friendliest way is a **double-click installer**. Build it once with:

```sh
bash build.sh pkg
```

That produces **`dist/BlackHolePlayground Installer.pkg`** and reveals it in Finder.
Double‑click the `.pkg` and the standard macOS installer walks you through it — no terminal
after this point. It installs to /Applications; open it from Spotlight or Launchpad.

Other options: `bash build.sh install` builds and drops the app straight into
/Applications and launches it; `bash build.sh` just builds into `./build`.

The first launch asks for **Screen Recording** — a dialog offers to open the exact
Settings pane; turn the app on there, then open it again.

### Gatekeeper (first open)

The app is **ad-hoc signed**, not notarized, so the very first time you open it macOS will
stop you. This is normal for any app not shipped through the App Store or signed with a
paid Developer ID. Get past it once and it opens normally forever:

- **macOS 13 / 14:** Control‑click (right‑click) the app in Finder → **Open** → **Open**.
- **macOS 15 Sequoia:** open **System Settings → Privacy & Security**, scroll to
  *"BlackHolePlayground was blocked,"* and click **Open Anyway**.

`bash build.sh install` strips the quarantine flag for you, so an app installed that way
usually opens directly; an app installed from the `.pkg` needs the one‑time confirmation.

**To remove the prompt entirely** you need an Apple Developer account ($99/yr): sign with a
Developer ID and notarize. The build accepts your identity —
`CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash build.sh pkg` — after
which you'd run `xcrun notarytool submit` / `xcrun stapler staple` on the result.

## Build options

`build.sh` needs only the Command Line Tools (the Metal shader is compiled at runtime, so
Xcode's `metal` toolchain isn't required). It compiles every `.swift` under `Sources/` and
bundles the icon and shader.

To build in **Xcode** instead:

1. **File ▸ New ▸ Project ▸ macOS ▸ App**, language Swift. (Interface/lifecycle choice
   doesn't matter — you'll delete the generated files.)
2. Delete the auto‑generated `*App.swift` / `ContentView.swift` / `AppDelegate`.
3. Drag the `Sources/` folder in (check *Copy items*, create groups).
   `Rendering/Shaders.metal` compiles automatically into the default Metal library.
4. In the target's **Info** tab add **Application is agent (UIElement)** = `YES`.
5. In **Signing & Capabilities**, leave App Sandbox **off** for local use.
6. Run. Grant Screen Recording permission, then run once more.

The app icon is generated from `Resources/C-logo.png`; rerun `tools/make-icon.sh` to
rebuild `Resources/AppIcon.icns` if you change the logo.

## Shortcuts

| Shortcut            | Action                                                       |
| ------------------- | ------------------------------------------------------------ |
| **⌥⌘B**             | Show / hide the control panel. Works everywhere, no setup.   |
| **Double-tap Esc**  | Quit immediately.                                            |
| `◍` menu-bar icon   | Controls + Quit. Always available, no permission needed.     |

⌥⌘B is a system‑wide hotkey, so it works no matter which app is in front — your reliable
way to summon the hidden panel (which has a big **Quit** button).

Double‑tap Esc is a bare key observed without consuming it, which on macOS requires
**Accessibility** permission to work inside *other* apps. Click **Enable the Esc quick‑exit**
in the panel (or *Enable Esc Quick‑Exit…* in the `◍` menu) and allow the app under
**Privacy & Security ▸ Accessibility**. Without that, just use ⌥⌘B → Quit, or the menu.

## Controls

The control panel opens on launch, then stays hidden until you recall it. It drives
everything live:

| Control                  | What it does                                                                                          |
| ------------------------ | ----------------------------------------------------------------------------------------------------- |
| Count                    | Number of black holes, **0–8**. Holes grow in when added and *collapse* when removed. 0 clears them all. |
| Size                     | Base event‑horizon radius (fraction of screen height).                                                |
| Size variation           | Per‑hole random size spread (0 = identical, 1 = wide).                                                 |
| Lensing                  | How strongly space bends. **Higher also reaches further** — at high settings a single hole warps the entire screen, smoothly. |
| Disk brightness          | Accretion‑disk intensity.                                                                             |
| Disk tilt                | Disk tilt angle (each hole also gets a small random offset).                                          |
| Spin                     | Disk rotation speed and direction (negative reverses).                                                |
| Glow                     | Ambient warm glow around each hole.                                                                   |
| **Motion**               | Still · Drift (bounce around) · Orbit (circle a center) · Gravity (mutual n‑body attraction).         |
| Speed                    | Overall rate of motion for the selected mode.                                                         |
| Fade when idle           | Holes shrink away when you stop using the Mac, return on activity.                                    |
| **Grow while you work**  | Holes (and the pet) swell and brighten while you're actively typing, easing back when you pause. On by default. |
| **Show file-eating pet** | Shows a small, draggable black‑hole window. Drop a file or folder onto it to send it to the **Trash** (recoverable). |
| **Click to pop**         | While on, click a hole on screen to collapse it. The overlay catches the click only when the cursor is over a hole, so the rest of the desktop stays usable. |
| Re-scatter               | Throw the holes into a fresh arrangement on fresh depth layers.                                       |
| **Vanish all**           | Collapse every hole at once (sets Count to 0). Raise Count to bring them back.                        |

Holes are spread across depth layers automatically, so with two or more on **Gravity** (or
just drifting past each other) you'll see a nearer hole visibly warp the disk and shadow of
one behind it. Farther holes are tinted redder and dimmed, like a cosmological redshift.

## The file-eating pet

Two behaviours turn the holes into a working companion:

- **A draggable pet that eats files → Trash.** Turn on **Show file-eating pet** and a small
  black‑hole window appears (drag it anywhere by its body). Drag any file or folder onto it:
  the pet flares and swallows it, and the item goes to the **Trash** — recoverable, never a
  permanent delete, and only ever triggered by a deliberate drop. The pet is its *own small
  window*, so the rest of your desktop stays interactive — you pick up a file normally and
  drop it on the pet. It also **lenses the desktop right behind it**, tapered to a soft round
  edge. macOS may ask once for permission to touch your Desktop/Downloads folder.
- **Grow while you work.** With **Grow while you work** on (the default), the holes and the
  pet swell, brighten, and spin up while you're actively typing, then ease back down when you
  pause — a quiet ambient readout of how heads‑down you are. It reads keyboard/track‑pad
  activity via the system idle timer, so it needs no permission and never logs anything.

> Why a separate pet window? A full‑screen drop target would have to intercept every click to
> receive a drop, making the desktop unusable. A small dedicated window is the right shape for
> "drop files here" without touching anything else on screen.

A few shape constants (disk flatten ratio, ring/halo radii, chromatic amount) are fixed near
the top and middle of `Sources/Rendering/Shaders.metal`; everything in the table above is
runtime.

## Project layout

```
Sources/
  App/        main.swift, AppDelegate.swift            — entry point + wiring
  Core/       ControlSettings.swift                    — shared, observable settings
              GPUTypes.swift                           — CPU mirror of the Metal structs
              Simulation.swift                         — CPU hole dynamics
              Idle.swift                               — system idle time (HID)
  Rendering/  Renderer.swift, Shaders.metal            — the Metal pass + fragment shader
  Capture/    ScreenCaptureManager.swift, FrameStore.swift — live screen feed + hand-off
  UI/         OverlayWindow.swift, PetWindow.swift, ControlPanel.swift — windows + panel
Resources/    C-logo.png, AppIcon.icns                 — logo + generated app icon
tools/        make-icon.sh                             — regenerate the icon from the logo
build.sh                                                — compile + bundle (no Xcode needed)
```

`build.sh` compiles every `.swift` under `Sources/` (any depth) and bundles `Shaders.metal`
+ `AppIcon.icns`, so you can rearrange the tree freely without editing the script.

## Known caveats

- **~1 frame of latency** in the lensed region — it samples the most recent capture, so
  fast‑moving content under the *soft edge* of the lens can shimmer faintly. Invisible under
  the strong distortion near the core.
- **High Lensing covers the whole screen.** That's intentional — at strong settings every
  hole reaches the edges. Where the overlay is opaque you're seeing the captured frame (one
  frame behind), but clicks still pass straight through to your real apps underneath. Lower
  Lensing to shrink the affected area.
- **Single display.** It captures and covers the main display only. Multi‑monitor is a
  straightforward extension (one capture + overlay per `SCDisplay`).
- **Permission re-prompts** when the signature changes — rebuilding with `build.sh` (ad‑hoc
  signature) or moving the `.app` can re‑trigger the Screen Recording prompt. A stable
  Developer ID signature avoids this.
- **Sharing the built app** to *another* Mac hits Gatekeeper (ad‑hoc, not notarized). On the
  Mac that built it, it launches with no friction. To distribute, sign with a Developer ID
  and notarize.
- **GPU cost scales with holes near a pixel**, not the total — but cranking Count, Size, and
  Lensing all the way up on a 5K display still makes the GPU work. If it stutters, drop the
  size or count a notch.

## Ideas / next steps

- **Per-hole editing** — select a hole and set its size/spin/tilt individually.
- **Merging / accretion** — when two holes overlap, combine them into a bigger one.
- **Save & load presets** of panel settings.
- **Multi-display** support (one capture + overlay per `SCDisplay`).
- **Hot reload** of `Shaders.metal` while iterating on the look.

## Credit & license

Released under the **MIT License** — see [`LICENSE`](LICENSE).

Ported from **s0xDk/ghostty-blackhole** (MIT), inspired by Eric Bruneton's black‑hole
shader. The lensing, accretion disk, photon ring, and Doppler‑beaming math come from that
project; the multi‑hole extension, screen‑capture, overlay, compositing, CPU simulation, and
control panel are this port. The upstream MIT notice is retained in `LICENSE`; keep it if you
redistribute.
