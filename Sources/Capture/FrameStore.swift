// FrameStore.swift — thread-safe hand-off of the latest captured desktop frame.
//
// ScreenCaptureManager delivers frames on its own queue; the pet samples them in its
// render loop on the display-link thread. This little lock-protected box bridges the two
// so the pet can lens the desktop behind it. (The overlay's Renderer keeps its own copy.)

import Foundation
import Metal
import CoreVideo

final class FrameStore {
    private let lock = NSLock()
    private var texture: MTLTexture?
    private var retained: CVMetalTexture?      // keep the IOSurface alive while the GPU samples it

    func set(texture: MTLTexture, retaining cv: CVMetalTexture) {
        lock.lock(); self.texture = texture; self.retained = cv; lock.unlock()
    }

    func current() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }; return texture
    }
}
