// ControlPanel.swift — the floating panel for tweaking the holes live.
//
// Shown on launch with a takeover warning + the shortcuts, then hidden until
// explicitly recalled (⌥⌘B or the menu-bar icon).
//
// NOTE: SwiftUI's ViewBuilder allows at most 10 direct children per block, so the
// sections below are wrapped in Groups to stay under that limit.

import SwiftUI
import AppKit
import ApplicationServices

struct ControlPanelView: View {
    @ObservedObject var settings: ControlSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                warningBanner
                holesSection
                dynamicsSection
                behaviourSection
                actionsSection
            }
            .padding(18)
        }
        .frame(width: 330, height: 720)
    }

    // MARK: sections

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Black holes are taking over your screen", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            HStack(spacing: 6) {
                Text("Show / hide panel:").bold()
                keycap("⌥"); keycap("⌘"); keycap("B")
                Text("— works anywhere").foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("Quit:").bold()
                keycap("esc"); keycap("esc")
                Text("· ◍ menu · the button below").foregroundStyle(.secondary)
            }
            Button {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            } label: {
                Label("Enable the Esc quick-exit (Accessibility)", systemImage: "lock.shield")
                    .font(.caption)
            }
            .buttonStyle(.link)
            Text("Close this panel when you're ready — the holes keep running. Bring it back with ⌥⌘B. (⌥⌘B works right away; double-tap Esc works in other apps once you allow Accessibility above.)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orange.opacity(0.35)))
    }

    private var holesSection: some View {
        Group {
            Text("Black Holes").font(.headline)
            Stepper(value: $settings.count, in: 0...8) {
                Text(settings.count == 0 ? "Count: none" : "Count: \(settings.count)")
            }
            .help("How many black holes. Set to 0 to clear them all.")
            slider("Size",            $settings.size,           0.02...0.18,
                   "Base size of each event horizon.")
            slider("Size variation",  $settings.sizeVariation,  0...1,
                   "How much the holes differ in size from each other.")
            slider("Lensing",         $settings.lensing,        0...0.6,
                   "How strongly space bends. Higher also reaches further — turn it up and a single hole warps the whole screen, with no hard edge.")
            slider("Disk brightness", $settings.diskBrightness, 0...3,
                   "Brightness of the glowing accretion disk.")
            slider("Disk tilt",       $settings.tilt,           0...Double.pi,
                   "Viewing angle of the disks.")
            slider("Spin",            $settings.spin,           -3...3,
                   "Disk rotation speed and direction (negative reverses).")
            slider("Glow",            $settings.glow,           0...0.1,
                   "Soft warm halo around each hole.")
        }
    }

    private var dynamicsSection: some View {
        Group {
            Divider()
            Text("Dynamics").font(.headline)
            Picker("Motion", selection: $settings.motion) {
                ForEach(MotionMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Still · Drift (bounce around) · Orbit (circle the center) · Gravity (the holes pull on each other).")
            slider("Speed", $settings.speed, 0...3, "How fast the holes move.")
        }
    }

    private var behaviourSection: some View {
        Group {
            Divider()
            Text("Behaviour").font(.headline)
            Toggle("Show file-eating pet", isOn: $settings.showPet)
                .help("Shows a small draggable black hole you can drop files onto to send them to the Trash. It's a separate little window, so the rest of your desktop stays fully usable — pick up a file and drag it onto the pet. Drag the pet itself to move it.")
            Toggle("Grow while you work", isOn: $settings.reactToActivity)
                .help("The holes (and the pet) swell and brighten while you're actively typing, and ease back down when you pause.")
            Toggle("Fade when idle", isOn: $settings.fadeWhenIdle)
                .help("Holes shrink away when you stop using the Mac, and return when you come back.")
            Toggle("Click to pop", isOn: $settings.clickToPop)
                .help("While on, click a black hole on screen to collapse it. The screen catches clicks while this is on.")
            Text("Turn on the pet, then drag a file onto it to feed it — devoured items go to the Trash, so nothing is ever lost for good.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionsSection: some View {
        Group {
            HStack(spacing: 10) {
                Button {
                    settings.resetToken += 1
                } label: {
                    Label("Re-scatter", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .help("Throw the holes into a fresh arrangement, on fresh layers.")

                Button(role: .destructive) {
                    settings.count = 0
                } label: {
                    Label("Vanish all", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .help("Collapse every hole. Raise the count to bring them back.")
            }
            .controlSize(.large)

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit black holes", systemImage: "xmark.octagon.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("Quit the app. (Or double-tap Esc.)")

            Text("Tip: a couple of holes on Gravity at different layers will visibly bend each other. Turn Lensing up and watch the desktop stretch between them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: helpers

    @ViewBuilder
    private func slider(_ label: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.3f", value.wrappedValue))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
        .help(help)
    }

    private func keycap(_ s: String) -> some View {
        Text(s)
            .font(.system(.caption, design: .monospaced)).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.20)))
    }
}

/// Builds the floating control window. It sits ABOVE the black-hole overlay (which
/// lives at screen-saver level), so the holes never draw over it, and it can take
/// focus so the sliders work. Our own windows are excluded from the screen capture,
/// so the panel is never lensed either.
func makeControlPanel(settings: ControlSettings) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 720),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
    panel.title = "Black Hole Controls"
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    // One level above the overlay's screen-saver window level → always on top of the holes.
    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: ControlPanelView(settings: settings))
    panel.center()
    return panel
}
