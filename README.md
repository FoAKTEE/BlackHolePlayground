# BlackHolePlayground

**Multiple** black holes that float over your **real macOS desktop** — lensing
your actual windows, Dock, and wallpaper, *and lensing each other* — with a live
control panel for their parameters and dynamics. Set how many there are, their
size and spread, lensing strength, disk look and spin, and turn them loose in one
of four motion modes (still, drifting, orbiting, or under mutual gravity).

Each hole sits on its own depth layer, so a nearer hole bends the apparent
position of the ones behind it and the farther ones are cosmologically
red-shifted (redder and dimmer). It opens with a control panel that warns you it's
about to take over the screen and shows the shortcuts — **double-tap Esc** to quit
and **⌥⌘B** to summon the panel — then gets out of your way.

This started as the [s0xDk/ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole)
shader (MIT) re-hosted outside the terminal. The single-hole math is extended to
N depth-sorted holes traced front-to-back; a small CPU simulation moves them and a
SwiftUI panel drives it.

## How it works

```
ScreenCaptureKit  ──frames──▶  Metal texture  ──▶  black-hole fragment shader
   (your app EXCLUDED                                        │
    from the capture)                                        ▼
                                          transparent, click-through overlay window
                                          (premultiplied alpha; opaque only where
                                           the hole actually distorts the desktop)
```

Three decisions carry the whole port:

1. **Self-exclusion to avoid the feedback loop.** The capture filter
   (`SCContentFilter`) excludes this app's own windows, so the overlay we draw is
   never captured and re-lensed. Without it you get an infinite mirror.
2. **Coverage-follows-effect alpha.** The shader outputs premultiplied alpha that
   is opaque only over the warp, disk, ring, glow, and shadow interior, and fully
   transparent everywhere else. The captured/real seam therefore lands exactly
   where the effect fades to zero, so it's invisible — and the live desktop stays
   live and interactive everywhere outside the hole.
3. **Depth-layered, front-to-back lensing.** Each hole has a depth; the holes are
   uploaded sorted nearest-first and the fragment shader marches the view ray
   through them front to back. A nearer hole bends the apparent position of the
   holes behind it (and the desktop), and its event horizon occludes whatever is
   deeper, while farther holes are red-shifted. The desktop sample still receives
   the *combined* deflection, so strong lensing warps the whole screen. Positions
   come from a tiny CPU n-body/orbit/drift simulation (`Simulation.swift`).

The shader stays cheap by skipping any hole whose influence doesn't reach the
current pixel, and by computing the expensive disk/ring/glow only right around
each hole — so cost tracks holes *near* a pixel, not the total count.

## Requirements

- macOS 13+ (14+ recommended), Apple Silicon or Intel.
- Xcode command-line tools (`xcode-select --install`).
- **Screen Recording** permission (granted on first launch).

## Install

The friendliest way is a **double-click installer**. Build it once with:

```sh
bash build.sh pkg
```

That produces **`dist/BlackHolePlayground Installer.pkg`** and reveals it in Finder.
**Double-click that .pkg** and the standard macOS installer walks you through it —
no terminal after this point. It installs to /Applications; open it from Spotlight
or Launchpad. The .pkg can be kept or shared, and re-installed entirely via the GUI.

> Why one terminal command first? A macOS app has to be *compiled* on a Mac, which
> needs the Xcode Command Line Tools (`xcode-select --install`). That single build
> step can't be skipped — but everything after it (installing, launching, sharing)
> is GUI. If `xcode-select --install` hasn't run yet, the script tells you.

Other options: `bash build.sh install` builds and drops the app straight into
/Applications and launches it; `bash build.sh` just builds into `./build`.

The first launch asks for **Screen Recording** permission — a dialog offers to open
the exact Settings pane; turn the app on there, then open it again. The control
panel opens on launch; toggle it or quit from the `◍` menu-bar item.

### Opening it the first time (Gatekeeper)

The app is **ad-hoc signed**, not notarized by Apple, so the very first time you
open it macOS will stop you. This is normal for any app not shipped through the App
Store or signed with a paid Developer ID. Get past it once and it opens normally
forever:

- **macOS 13 / 14:** Control-click (right-click) the app in Finder → **Open** →
  **Open**.
- **macOS 15 Sequoia:** open  → **System Settings → Privacy & Security**, scroll
  to *"BlackHolePlayground was blocked,"* and click **Open Anyway**.

`bash build.sh install` strips the quarantine flag for you, so an app installed
that way usually opens directly; an app installed from the **.pkg** needs the
one-time confirmation above.

**To remove the prompt entirely** you need an Apple Developer account ($99/yr):
sign with a Developer ID and notarize. The build already accepts your identity —
`CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash build.sh pkg`
— after which you'd run `xcrun notarytool submit` / `xcrun stapler staple` on the
result. Without that, the one-time "Open Anyway" is the expected path.

## Build & run — Xcode

1. **File ▸ New ▸ Project ▸ macOS ▸ App.** Language Swift. (Interface/lifecycle
   choice doesn't matter — you'll delete the generated files.)
2. Delete the auto-generated `*App.swift` / `ContentView.swift` / `AppDelegate`.
3. Drag the `Sources/` folder into the project (check *Copy items*, create groups).
   `Rendering/Shaders.metal` compiles automatically into the default Metal library.
4. In the target's **Info** tab add **Application is agent (UIElement)** = `YES`.
5. In **Signing & Capabilities**, leave App Sandbox **off** for local use
   (sandbox + screen capture needs extra entitlements you don't want to fight for
   a personal tool). Automatic signing with your own team is fine.
6. Run. Grant Screen Recording permission, then run once more.

## Shortcuts

| Shortcut             | Action                                                            |
| -------------------- | ---------------------------------------------------------------- |
| **⌥⌘B**              | Show / hide the control panel. **Works everywhere, no setup.**    |
| **Double-tap Esc**   | Quit immediately.                                                 |
| `◍` menu-bar icon    | Controls + Quit. Always available, no permission needed.          |

⌥⌘B is a system-wide hotkey, so it works no matter which app is in front — that's
your reliable way to summon the hidden panel (which has a big **Quit** button).

Double-tap Esc is a bare key observed without consuming it, which on macOS requires
**Accessibility** permission to work inside *other* apps. Click **Enable the Esc
quick-exit** in the panel (or *Enable Esc Quick-Exit…* in the `◍` menu) and allow
the app under **Privacy & Security ▸ Accessibility**. Without that, just use ⌥⌘B →
Quit, or the menu — both always work.

## Controls

The control panel **opens on launch** with a takeover warning and the shortcuts,
then stays hidden until you recall it (⌥⌘B or the `◍` menu). It drives everything
live:

| Control            | What it does                                                        |
| ------------------ | ------------------------------------------------------------------- |
| Count              | Number of black holes, **0–8**. Holes grow in when added and *collapse* when removed. 0 clears them all. |
| Size               | Base event-horizon radius (fraction of screen height).              |
| Size variation     | Per-hole random size spread (0 = identical, 1 = wide).              |
| Lensing            | How strongly space bends. **Higher also reaches further** — at high settings a single hole warps the entire screen, smoothly, with no hard edge. Reach is the same for every hole regardless of its size. |
| Disk brightness    | Accretion-disk intensity.                                           |
| Disk tilt          | Disk tilt angle (each hole also gets a small random offset).        |
| Spin               | Disk rotation speed and direction (negative reverses).              |
| Glow               | Ambient warm glow around each hole.                                 |
| **Motion**         | Still · Drift (bounce around) · Orbit (circle a center) · Gravity (mutual n-body attraction). |
| Speed              | Overall rate of motion for the selected mode.                       |
| Fade when idle     | Holes shrink away when you stop using the Mac, return on activity.  |
| **Grow while you work** | Holes swell and brighten while you're actively typing, easing back down when you pause. On by default. |
| **Show file-eating pet** | Shows a small, draggable black-hole window. Drop a file or folder onto it to send the file to the **Trash** (recoverable). It's a separate little window, so the rest of your desktop stays fully usable. |
| **Click to pop**   | While on, click a black hole on screen to collapse it. The screen catches clicks while this is on. |
| Re-scatter         | Throw the holes into a fresh arrangement on fresh depth layers.     |
| **Vanish all**     | Collapse every hole at once (sets Count to 0). Raise Count to bring them back. |

Holes are spread across depth layers automatically, so with two or more on
**Gravity** (or just drifting past each other) you'll see a nearer hole visibly
warp the disk and shadow of one behind it. Farther holes are tinted redder and
dimmed, like a cosmological redshift.

## Desktop pet: feed it files, watch it react

Two behaviours turn the holes into a working companion:

- **A draggable pet that eats files → Trash.** Turn on **Show file-eating pet** and a
  small black-hole window appears (drag it anywhere by its body). Drag any file or
  folder from your Desktop onto it: the pet flares and swallows it, and the item
  goes to the **Trash** — recoverable, never a permanent delete, and only ever
  triggered by a deliberate drop. Crucially the pet is its *own small window*, so
  the rest of your desktop stays completely interactive — you pick up a file
  normally and drop it on the pet. macOS may ask once for permission to touch your
  Desktop/Downloads folder the first time. (The pet draws the same Metal black hole
  as the overlay, just self-contained on a transparent background.)
- **Grow while you work.** With **Grow while you work** on (the default), the holes
  and the pet swell, brighten, and spin up while you're actively typing, then ease
  back down when you pause — a quiet ambient readout of how heads-down you are. It
  reads keyboard/track-pad activity via the system idle timer, so it needs no
  permission and never logs anything.

> Why a separate pet window? A full-screen drop target would have to intercept
> every click to receive a drop, which makes the desktop unusable — you couldn't
> even start dragging an icon. A small dedicated window is the right shape for
> "drop files here" without touching anything else on screen.

A few shape constants (disk flatten ratio, ring/halo radii, chromatic amount) are
still fixed near the top and middle of `Sources/Rendering/Shaders.metal` if you want
to dig deeper; everything in the table above is runtime.

## Project layout

The sources are grouped by concern under `Sources/`:

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
```

`build.sh` compiles every `.swift` under `Sources/` (any depth) and bundles
`Shaders.metal`, so you can rearrange the tree freely without editing the script.

## Known caveats (the honest ones)

- **~1 frame of latency** in the lensed region — it samples the most recent
  capture, so fast-moving content under the *soft edge* of the lens can shimmer
  faintly. Invisible under the strong distortion near the core.
- **High Lensing covers the whole screen.** That's intentional — at strong
  settings every hole reaches the edges. Where the overlay is opaque you're seeing
  the captured frame (one frame behind) rather than the truly-live pixels, but
  clicks still pass straight through to your real apps underneath, so nothing
  becomes unusable. Lower Lensing to shrink the affected area back down.
- **Single display.** It captures and covers the main display only. Multi-monitor
  is a straightforward extension (one capture + overlay per `SCDisplay`).
- **Permission re-prompts** when the signature changes — rebuilding with `build.sh`
  (ad-hoc signature) or moving the `.app` can re-trigger the Screen Recording
  prompt. A stable Developer ID signature avoids this.
- **Sharing the built app** to *another* Mac will hit Gatekeeper, because it's
  ad-hoc signed, not notarized. On the Mac that built it, it launches with no
  Gatekeeper friction (locally built apps aren't quarantined). To distribute it,
  sign with a Developer ID and notarize.
- The real mouse cursor is drawn by the system on top of everything, so it stays
  undistorted as it passes over the hole (capture has `showsCursor = false` to
  avoid a doubled cursor).

- **GPU cost scales with holes near a pixel**, not the total — but cranking Count,
  Size, and Lensing all the way up on a 5K display will still make the GPU work.
  If it ever stutters, drop the size or count a notch.

## Ideas / next steps

- **Per-hole editing** — select a hole and set its size/spin/tilt individually
  (right now those are global plus a little per-hole randomness).
- **Merging / accretion** — when two holes overlap, combine them into a bigger one.
- **Save & load presets** of panel settings.
- **Multi-display** support (one capture + overlay per `SCDisplay`).
- **Hot reload** of `Shaders.metal` while iterating on the look.

## Credit & license

Released under the **MIT License** — see [`LICENSE`](LICENSE).

Ported from **s0xDk/ghostty-blackhole** (MIT), inspired by Eric Bruneton's
black-hole shader. The lensing, accretion disk, photon ring, and Doppler-beaming
math come from that project; the multi-hole extension, screen-capture, overlay,
compositing, CPU simulation, and control panel are this port. The upstream MIT
notice is retained in `LICENSE`; keep it if you redistribute.
