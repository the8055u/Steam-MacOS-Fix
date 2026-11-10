// steamfix-agent — background agent (LaunchAgent local.steamfix.agent).
//
// The fix only applies when Steam is started through "Steam (fix).app". This agent covers every
// other way Steam gets started (stock Dock icon, login item, Steam restarting itself after an
// update): when a Steam client process appears that was not started through the launcher, it is
// stopped right at launch — before it has opened anything — and the launcher is run instead.
//
// It deliberately does very little:
//   * only a client that is alone and has just started is touched (never a session in progress,
//     never a second invocation such as "steam_osx -shutdown" or a click on the icon while Steam
//     is already running);
//   * if the relaunch does not come up with the fix, it backs off for hours instead of looping;
//   * an empty file named "no-auto" in the launcher's Contents/Resources turns it off.
//
// usage: steamfix-agent "/path/to/Steam (fix).app"

import AppKit
import Darwin

guard CommandLine.arguments.count > 1 else { exit(0) }
let launcherURL = URL(fileURLWithPath: CommandLine.arguments[1])
let resourcesURL = launcherURL.appendingPathComponent("Contents/Resources")
let clientSuffix = "/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SteamFix-agent.log")

func log(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(message)\n"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
       let size = attrs[.size] as? Int, size > 200_000 {
        try? FileManager.default.removeItem(at: logURL)
    }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - process inspection

func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(got, 0))).filter { $0 > 0 }
}

func path(of pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

func startTime(of pid: pid_t) -> Date? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
}

/// Arguments and environment the process was started with.
func argsAndEnv(of pid: pid_t) -> (args: [String], env: [String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }      // executable path
    while i < size && buf[i] == 0 { i += 1 }      // padding
    var strings: [String] = []
    var start = i
    while i < size {
        if buf[i] == 0 {
            if i == start { break }               // end of the string area
            strings.append(String(decoding: buf[start..<i], as: UTF8.self))
            start = i + 1
        }
        i += 1
    }
    guard strings.count >= argc else { return nil }
    return (Array(strings.prefix(argc)), Array(strings.dropFirst(argc)))
}

func steamClients() -> [pid_t] {
    allPids().filter { path(of: $0)?.hasSuffix(clientSuffix) == true }
}

func hasFix(_ env: [String]) -> Bool {
    env.contains { $0.hasPrefix("DYLD_INSERT_LIBRARIES=") && $0.contains("libsteamfix") }
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

// MARK: - takeover

var lastRelaunch = Date.distantPast
var backOffUntil = Date.distantPast

func enabled() -> Bool {
    let fm = FileManager.default
    return fm.isExecutableFile(atPath: launcherURL.appendingPathComponent("Contents/MacOS/launch").path)
        && fm.fileExists(atPath: resourcesURL.appendingPathComponent("libsteamfix.dylib").path)
        && !fm.fileExists(atPath: resourcesURL.appendingPathComponent("no-auto").path)
}

func runLauncher(arguments: [String]) {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.arguments = arguments
    cfg.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: launcherURL, configuration: cfg) { _, error in
        if let error = error { log("could not start the launcher: \(error.localizedDescription)") }
    }
}

func takeOver(_ pid: pid_t, arguments: [String]) {
    log("Steam client \(pid) was started without the fix; restarting it through the launcher")
    kill(pid, SIGKILL)
    for _ in 0..<40 where isAlive(pid) { usleep(50_000) }
    // Anything it managed to start in those first moments.
    for p in allPids() where p != pid {
        guard let exe = path(of: p), exe.hasSuffix("/Steam Helper"),
              let ae = argsAndEnv(of: p), ae.args.contains("-steampid=\(pid)") else { continue }
        kill(p, SIGKILL)
    }
    lastRelaunch = Date()
    usleep(400_000)
    runLauncher(arguments: arguments)

    // The launcher normally brings Steam up within a second or two. If nothing is running a
    // while later (Steam sometimes refuses to start right after another instance died), try once more.
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        if steamClients().isEmpty {
            log("Steam did not come up; starting the launcher again")
            lastRelaunch = Date()
            runLauncher(arguments: arguments)
        }
    }
}

func scan() {
    guard enabled() else { return }
    let clients = steamClients()
    guard clients.count == 1, let pid = clients.first else { return }           // none, or a second invocation
    guard let ae = argsAndEnv(of: pid), !hasFix(ae.env) else { return }         // already started through the launcher
    guard !ae.args.dropFirst().contains("-shutdown") else { return }
    guard let started = startTime(of: pid), Date().timeIntervalSince(started) < 20 else { return }   // never a session in progress
    let now = Date()
    guard now >= backOffUntil else { return }
    if now.timeIntervalSince(lastRelaunch) < 60 {
        // This is the client our own relaunch produced, and it still has no fix.
        backOffUntil = now.addingTimeInterval(6 * 3600)
        log("the launcher did not apply the fix; leaving Steam alone for 6 hours")
        return
    }
    takeOver(pid, arguments: Array(ae.args.dropFirst()))
}

// MARK: - watching

var watchUntil = Date.distantPast
var timer: Timer?

func watch(for seconds: TimeInterval) {
    watchUntil = max(watchUntil, Date().addingTimeInterval(seconds))
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { t in
        scan()
        if Date() > watchUntil {
            t.invalidate()
            timer = nil
        }
    }
}

NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                  object: nil, queue: .main) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    let isSteam = app.bundleIdentifier == "com.valvesoftware.steam"
        || app.executableURL?.path.hasSuffix(clientSuffix) == true
    // Steam's bootstrapper hands over to the client some time after it launches (longer when it
    // is installing an update), so keep looking for a while.
    if isSteam { watch(for: 120) }
}

log("agent started for \(launcherURL.path)")
watch(for: 3)     // Steam may have been started a moment before this agent
RunLoop.main.run()
