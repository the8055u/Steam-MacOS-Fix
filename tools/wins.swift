// Lists the windows of Steam's processes as the window server sees them.
// usage: wins [--all]     (without --all, untitled windows such as pre-created menus are skipped)
//
// One line per window:  <pid> <window id> <on-screen 0|1> <x> <y> <width> <height> <title>
// Under Stage Manager a window parked in the strip is reported on-screen at thumbnail size
// (roughly 120 points wide) near the left edge, which is how tools/stagetest.sh recognises it.
import CoreGraphics
import Foundation

let showAll = CommandLine.arguments.contains("--all")
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard let pid = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
    let exe = String(cString: buf)
    guard exe.hasSuffix("/Steam Helper") || exe.hasSuffix("/steam_osx") else { continue }
    guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
    let title = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
    let width = b["Width"] as? Double ?? 0, height = b["Height"] as? Double ?? 0
    if !showAll && (title.isEmpty || width < 50 || !exe.hasSuffix("/Steam Helper")) { continue }
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Int ?? 0) != 0 ? 1 : 0
    print(pid, w[kCGWindowNumber as String] ?? 0, onscreen, Int(x), Int(y), Int(width), Int(height), title)
}
