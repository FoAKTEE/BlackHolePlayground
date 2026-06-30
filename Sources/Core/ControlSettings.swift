// ControlSettings.swift — the single source of truth for everything tunable.
//
// The SwiftUI control panel writes to it and the renderer + simulation read from it
// (all on the main thread). It's the only state shared across the app's modules.

import Foundation
import Combine

/// How the holes move when more than "still".
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
    @Published var count: Int = 3              // number of black holes (0...8)
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
    @Published var showPet: Bool = false       // show the small draggable file-eating pet
    @Published var reactToActivity: Bool = true // grow brighter while you're actively working
    @Published var resetToken: Int = 0         // bump to re-scatter positions
}
