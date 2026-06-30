// main.swift — programmatic entry point.
// Runs as an "accessory" app: no Dock icon, lives in the menu bar.

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
