// Sends a debug command to the library inside a running Steam. Only works when the launcher has
// the "debug" switch (see README); answers go to ~/Library/Logs/SteamFix.log.
//
// usage: sfcmd "<process>:<command>"     process = main (steam_osx) or helper (Steam Helper)
//   helper:dump          activation policy, menu bar and windows as the helper sees them
//   main:dump            the same for steam_osx
//   helper:menu 2 0      trigger item 0 of top-level menu 2 through the menu proxy
//   helper:policy 1      set the activation policy (0 regular, 1 accessory) — experiments only
import Foundation

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: sfcmd \"helper:dump\"\n".data(using: .utf8)!)
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(.init("local.steamfix.cmd"), object: CommandLine.arguments[1],
                                                             userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
