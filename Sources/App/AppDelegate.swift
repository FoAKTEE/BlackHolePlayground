// AppDelegate.swift — wires everything together.

import Cocoa
import Metal
import Combine
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let device = MTLCreateSystemDefaultDevice()!
    private let settings = ControlSettings()
    private let sim = Simulation()
    private var window: OverlayWindow!
    private var renderer: Renderer!
    private var capture: ScreenCaptureManager!
    private var controlPanel: NSPanel!
    private var petWindow: PetWindow?
    private var statusItem: NSStatusItem!
    private var overlayStarted = false
    private let frameStore = FrameStore()        // latest captured frame, shared with the pet
    private var cancellables = Set<AnyCancellable>()

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var lastEscPress: TimeInterval = 0

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        // The control panel, global shortcuts, and the file-eating pet do NOT need Screen
        // Recording — wire them up first so the pet can appear and send files to the Trash
        // even when the desktop-lensing permission is missing or still pending. (Killing the
        // whole app at the permission gate used to take the pet down with it.)
        settings.$showPet
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.setPetVisible(show) }
            .store(in: &cancellables)

        // Shortcuts. ⌥⌘B (toggle panel) is a Carbon hotkey: works everywhere, no permission.
        // Double-tap Esc (quit) uses event monitors and needs Accessibility to reach other apps.
        registerPanelHotKey()
        installEscMonitors()

        // Control panel appears FIRST (with the takeover warning + shortcuts), above the
        // black holes. After the user closes it, it stays hidden until recalled with ⌥⌘B
        // or the menu-bar icon.
        controlPanel = makeControlPanel(settings: settings)
        controlPanel.makeKeyAndOrderFront(nil)
        controlPanel.orderFrontRegardless()

        // The full-screen overlay that lenses your live desktop DOES need Screen Recording
        // (via ScreenCaptureKit; grants take effect on the next launch). Bring it up if it's
        // granted; otherwise prompt WITHOUT quitting, so the pet and panel keep working.
        if CGPreflightScreenCaptureAccess() {
            startOverlayAndCapture()
        } else {
            requestScreenRecording()
        }
    }

    /// Bring up the desktop-lensing overlay and the live screen capture. Requires Screen
    /// Recording permission; everything else (panel, shortcuts, pet) runs without it.
    private func startOverlayAndCapture() {
        guard !overlayStarted else { return }
        guard let screen = mainScreen() else {
            alertAndQuit("No display", "Could not locate the main display.")
            return
        }
        overlayStarted = true

        // Transparent, click-through overlay covering the main display.
        window = OverlayWindow(screen: screen, device: device)
        renderer = Renderer(mtkView: window.mtkView, settings: settings, sim: sim)
        window.mtkView.delegate = renderer
        window.mtkView.onClick = { [weak self] nx, ny in self?.handlePopClick(nx, ny) }
        window.orderFrontRegardless()

        // "Click to pop": the overlay must swallow the click to collapse a hole — but only
        // RIGHT OVER a hole. The renderer tracks whether the cursor is over a hole and flips
        // the overlay click-through accordingly, so the rest of the desktop (and the pet)
        // stay fully usable instead of the whole screen eating every click.
        renderer.onMouseCaptureChanged = { [weak self] capture in
            self?.window?.ignoresMouseEvents = !capture
        }

        // Live capture of the same display, with our own app excluded (no feedback loop).
        // Hand each frame to the overlay renderer AND the pet (so the pet can lens the
        // desktop behind it).
        capture = ScreenCaptureManager(displayID: screen.displayID, device: device) {
            [weak self] texture, cvTexture in
            self?.renderer.update(texture: texture, retaining: cvTexture)
            self?.frameStore.set(texture: texture, retaining: cvTexture)
        }
        Task {
            do {
                try await capture.start()
            } catch {
                await MainActor.run { self.alertAndQuit("Capture failed", "\(error)") }
            }
        }
    }

    // MARK: shortcuts

    /// System-wide ⌥⌘B via Carbon — fires no matter which app is in front, no permission needed.
    private func registerPanelHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let eventRef = eventRef, let userData = userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(eventRef,
                                            EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID),
                                            nil,
                                            MemoryLayout<EventHotKeyID>.size,
                                            nil,
                                            &hkID)
                if err == noErr {
                    Unmanaged<AppDelegate>.fromOpaque(userData)
                        .takeUnretainedValue().handleHotKey(hkID.id)
                }
                return OSStatus(noErr)
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef)

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: fourCharCode("BHky"), id: 1)
        _ = RegisterEventHotKey(UInt32(kVK_ANSI_B),
                                UInt32(cmdKey | optionKey),
                                id,
                                GetApplicationEventTarget(),
                                0,
                                &ref)
        hotKeyRef = ref
    }

    private func handleHotKey(_ id: UInt32) {
        if id == 1 { toggleControls() }
    }

    /// Double-tap Esc to quit. Works in other apps once Accessibility is allowed; always
    /// works while our own panel is focused.
    private func installEscMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            _ = self?.handleEsc(e)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            (self?.handleEsc(e) ?? false) ? nil : e
        }
    }

    @discardableResult
    private func handleEsc(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }       // Esc
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleTap = (now - lastEscPress) < 0.4
        lastEscPress = now
        if isDoubleTap { quit(); return true }
        return false                                          // single Esc passes through
    }

    @objc private func enableGlobalShortcuts() {
        // Prompts the user to allow this app under Privacy & Security ▸ Accessibility,
        // which lets the double-tap-Esc quit work from inside other apps.
        // (Literal key value of kAXTrustedCheckOptionPrompt — avoids SDK import quirks.)
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: interactions

    private func handlePopClick(_ nx: Float, _ ny: Float) {
        guard settings.clickToPop else { return }   // in devour-only mode, clicks shouldn't pop
        let size = window.mtkView.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        if sim.popNearest(uvX: nx, uvY: ny, base: Float(settings.size), aspect: aspect) {
            settings.count = max(0, settings.count - 1)   // don't let it respawn
        }
    }

    /// Show/hide the small file-eating pet window (created on first use).
    private func setPetVisible(_ show: Bool) {
        if show {
            if petWindow == nil {
                let p = PetWindow(device: device, settings: settings, frameStore: frameStore)
                p.petView.onDrop = { [weak self] urls in self?.devour(urls) }
                petWindow = p
            }
            petWindow?.orderFrontRegardless()
        } else {
            petWindow?.orderOut(nil)
        }
    }

    /// A file was dropped on the pet → move it to the Trash (recoverable, never permanent).
    /// Surface failures instead of swallowing them: a denied-folder permission, a locked
    /// file, or a read-only volume would otherwise leave the item in place while the pet
    /// flares as if it ate it — looking exactly like "the pet doesn't work."
    private func devour(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            guard let error = error else { return }            // success: nothing to report
            NSLog("pet: move to Trash failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self?.reportTrashFailure(error) }
        }
    }

    private func reportTrashFailure(_ error: Error) {
        let a = NSAlert()
        a.messageText = "Couldn’t move that to the Trash"
        a.informativeText = error.localizedDescription
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    @objc private func toggleControls() {
        guard let panel = controlPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: setup helpers

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◍"
        let menu = NSMenu()
        let header = NSMenuItem(title: "Black Hole Playground", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show / Hide Controls  (⌥⌘B)", action: #selector(toggleControls), keyEquivalent: "")
        menu.addItem(withTitle: "Enable Esc Quick-Exit…", action: #selector(enableGlobalShortcuts), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit  (double-tap Esc)", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func mainScreen() -> NSScreen? {
        let main = CGMainDisplayID()
        return NSScreen.screens.first { $0.displayID == main } ?? NSScreen.main
    }

    /// Prompt for Screen Recording WITHOUT quitting. The desktop-lensing overlay needs it,
    /// but the menu bar, control panel, and file-eating pet do not — so we keep running and
    /// let the user grant it and relaunch for the overlay (grants take effect next launch).
    private func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "Screen Recording needed for the desktop lensing"
        a.informativeText = """
        The black holes that bend your live desktop need Screen Recording. The file-eating \
        pet works without it — turn on “Show file-eating pet” and drop files on it any time.

        1. Click “Open Settings”.
        2. Turn on this app under Screen Recording.
        3. Quit and reopen the app to see the desktop lensing.
        """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Continue (pet only)")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            _ = NSWorkspace.shared.open(url)
        }
        // Intentionally do NOT quit — the pet and panel stay live.
    }

    private func alertAndQuit(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
        NSApp.terminate(nil)
    }
}

private func fourCharCode(_ s: String) -> OSType {
    var code: OSType = 0
    for b in s.utf8.prefix(4) { code = (code << 8) | OSType(b) }
    return code
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
    }
}
