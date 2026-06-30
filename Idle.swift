// Idle.swift — seconds since the last keyboard/mouse/trackpad event.
//
// This is the desktop replacement for Ghostty's per-terminal `iTimeCursorChange`.
// Reading HIDIdleTime needs no special permission (unlike an event tap), and it
// captures activity anywhere on the system.

import Foundation
import IOKit

func systemIdleSeconds() -> Double {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IOHIDSystem"),
                                       &iterator) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iterator) }

    let entry = IOIteratorNext(iterator)
    guard entry != 0 else { return 0 }
    defer { IOObjectRelease(entry) }

    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &properties,
                                            kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = properties?.takeRetainedValue() as? [String: Any],
          let idle = dict["HIDIdleTime"] as? NSNumber else { return 0 }

    return idle.doubleValue / 1_000_000_000.0   // nanoseconds -> seconds
}
