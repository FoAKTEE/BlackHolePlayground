// OverlayWindow.swift — the transparent, click-through canvas the holes are drawn on.
//
// Normally clicks pass straight to the desktop. "Click to pop" flips the window to
// catch clicks so a hole under the cursor can be collapsed. (File-eating lives in
// its own small PetWindow, so the full-screen overlay never blocks the desktop.)

import Cocoa
import MetalKit
import QuartzCore

/// MTKView that reports clicks in normalized, top-left-origin coordinates.
final class OverlayMTKView: MTKView {
    /// Click at (x, y) in 0...1, top-left origin. Fires only when not click-through.
    var onClick: ((Float, Float) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let nx = Float(p.x / b.width)
        let ny = Float(1.0 - p.y / b.height)   // flip to top-left origin (matches shader)
        onClick?(nx, ny)
    }
}

final class OverlayWindow: NSWindow {
    let mtkView: OverlayMTKView

    init(screen: NSScreen, device: MTLDevice) {
        let view = OverlayMTKView(frame: screen.frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)        // transparent clear
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.isOpaque = false        // let the desktop show through
        mtkView = view

        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true                              // clicks pass through by default
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        // Float above ordinary windows, on every Space, and over full-screen apps.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        contentView = view
        setFrame(screen.frame, display: true)
    }

    // Never steal focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
