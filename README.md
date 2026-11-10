# steamfix

English | [Русский](README.ru.md)

Makes the Steam client on macOS behave like an ordinary app as far as the system is concerned:

- Steam's windows get the standard macOS window shape (system corner radius, border, shadow);
- Stage Manager moves Steam's windows to the strip and back, as it does for any other app;
- the Dock shows a single Steam tile, the same one Steam is launched from.

Steam's files are not modified or re-signed. Everything is done by a library that is loaded
into the client at launch, and a background agent that makes sure Steam starts with it.

## Requirements

- macOS on Apple silicon or Intel; tested on macOS 27.2 (26B123).
- Steam installed and started at least once (`/Applications/Steam.app`).
- Xcode Command Line Tools (`xcode-select --install`): `clang` and `swiftc` are needed.

## Installation

```sh
make install
```

Then quit Steam if it is running and open it the usual way. To check the result:

```sh
make status        # changes nothing, only reports the current state
make stagetest     # switches apps on screen to check Stage Manager
```

Run `make stagetest` from the app that is currently active (for example, a Terminal window in
front) and with a Steam window open: macOS does not let a background script take focus, and in
that case the test reports that it could not be run.

To remove everything, run `make uninstall` and restart Steam.

`make install` can be run again: it rebuilds everything and replaces the installed copy,
keeping the switches. On the first install macOS shows a notification about a new background
item, `steamfix-agent`.

What goes where:

| Path | What it is |
| --- | --- |
| `~/Library/Application Support/SteamFix/Steam (fix).app` | launcher, library, agent |
| `~/Library/LaunchAgents/local.steamfix.agent.plist` | starts the agent at login |
| `~/Library/Logs/SteamFix-agent.log` | agent log (a few lines per Steam launch) |

## Why this is needed

Steam on macOS is two apps. `steam_osx` owns the Dock icon and the menu bar but has no windows
of its own. Every visible window belongs to the `Steam Helper` process, a background agent
(`LSUIElement`) that draws borderless windows through SDL. To the system these are borderless
windows of a background process: the corners are square, and Stage Manager does not manage
such windows.

## How it works

**Launcher** — [src/launcher.sh](src/launcher.sh). Starts the client
(`~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx`) with
`DYLD_INSERT_LIBRARIES` pointing at the library. This is possible because neither the client
nor `Steam Helper` uses the hardened runtime.

**Library** — [src/steamfix.m](src/steamfix.m). It behaves differently in the two processes:

- In `steam_osx`:
  - removes `DYLD_INSERT_LIBRARIES` from the environment and adds it back only when starting
    the `Steam Helper` browser process, so games and all other child processes never get the
    library;
  - starts as a background app and keeps itself out of the Dock while `Steam Helper` is alive;
  - serves its menu and accepts commands from `Steam Helper` (menu item, reopen, quit,
    `steam://` link) over a `CFMessagePort` named `local.steamfix.<pid>`;
  - drops its own "activate myself when the helper becomes active" reaction; otherwise two
    regular apps keep taking focus from each other forever.
- In `Steam Helper` (browser process only, the one without `--type=`):
  - adds `titled | closable | fullSizeContentView` to the style of SDL windows and hides the
    system title bar: the window gets the system shape while Steam still draws its content;
    popup menus and Big Picture are left alone (recognised by `SDL_GetWindowFlags`);
  - makes the process a regular app (`NSApplicationActivationPolicyRegular`), which is all it
    takes for Stage Manager to manage its windows;
  - shows a copy of `steam_osx`'s menu in the menu bar; choosing an item runs it in `steam_osx`;
  - when registering with LaunchServices (`_LSApplicationCheckIn`), reports the path
    `/Applications/Steam.app` instead of its own. The Dock matches tiles by exactly this path,
    so there is one tile. Nothing changes inside the process itself;
  - since the system now treats it as the Steam app, Dock icon clicks, Quit and `steam://`
    links are delivered to it; it forwards them to `steam_osx`.

**Agent** — [src/agent.swift](src/agent.swift), LaunchAgent `local.steamfix.agent`. Steam
started from its ordinary icon, from login items, or restarted by itself comes up without the
library. The agent notices such a client within the first second, stops it and runs the
launcher. It only touches a client that is alone and has just started; second invocations and
a session already in progress are left alone. If Steam still has no fix after the agent's own
relaunch, it backs off for 6 hours instead of looping.

## Switches

An empty file with one of these names in
`~/Library/Application Support/SteamFix/Steam (fix).app/Contents/Resources`
(takes effect the next time Steam starts):

| File | Effect |
| --- | --- |
| `no-shape` | keep Steam's square windows |
| `no-stage` | do not make `Steam Helper` a regular app (Stage Manager, the menu and the shared tile are all off) |
| `no-rename` | do not register as `/Applications/Steam.app` (Steam gets a second tile) |
| `no-auto` | the agent does not step in; the fix applies only when started through the launcher |
| `debug` | write the library's log to `~/Library/Logs/SteamFix.log` |

To start Steam with the fix by hand, bypassing the agent:
`open "$HOME/Library/Application Support/SteamFix/Steam (fix).app"`.

## Tested

| | |
| --- | --- |
| macOS | 27.2 (26B123), Apple M5 |
| Steam | client 1792618285, bootstrapper 6.1 |
| Build | Apple clang 21.0.0, Swift 6.4.2 |

Checked: window shape, windows moving to the Stage Manager strip and back, one Dock tile when
launched the ordinary way, clicking the icon while Steam is running, the menu, the link
`steam://open/downloads`, quitting through the tile, the library being absent from child
processes, the agent refusing to loop.

Not checked: launching games and the overlay, Big Picture, full screen, autostart at login,
Steam restarting itself after its own update.

## Limitations and risks

- This tampers with a running client. The library depends on Steam's internals (SDL class
  names, the order in which processes start) and on an undocumented LaunchServices function.
  A Steam or macOS update can break it; `make uninstall` or the relevant switch brings back
  the stock behaviour.
- Valve gives no guarantees for a modified client. The library is not passed on to games, but
  consequences for the account cannot be ruled out.
- If Steam is not running, the first `steam://` link may be lost: the agent restarts the
  client and the address does not reach the new instance.
- The agent does not touch a Steam that has been running for more than 20 seconds. If Steam
  starts noticeably earlier than the agent at login, that session stays without the fix until
  Steam is restarted.

## What did not work

Recorded so nobody has to go down these paths again.

- `LSUIElement = false` in `Steam Helper`'s `Info.plist`: Steam restores the file at launch;
  if the file is locked, client updates break, and the two apps take focus from each other
  endlessly.
- Window `collectionBehavior` flags (including `Primary`) have no effect on Stage Manager
  while the window's owner is a background app.
- A window style without `closable`: CEF closes the sign-in window with `performClose:`, and
  without this flag the call is ignored and an empty sign-in window stays behind the main one.
- A wrapper `Steam.app` around `Steam Helper` (a copy of the executable, everything else
  linked) gives the tile the right label but results in two tiles. The `Info.plist` in such a
  copy must not be edited: Valve's signature no longer matches and macOS kills the process at
  launch (exit code 137).
- Re-signing the copy ad hoc runs, but the process loses access to the "Steam Safe Storage"
  key in the keychain.
- The Dock does not merge tiles by bundle identifier, only by the registered path.
  `_LSSetApplicationInformationItem` does not change the path after registration.
- The `CFProcessPath` environment variable also gives one tile, but it replaces the main
  bundle inside the process, which is where CEF looks for its resources.

## Debugging

```sh
touch "$HOME/Library/Application Support/SteamFix/Steam (fix).app/Contents/Resources/debug"
# restart Steam, then:
tail -f ~/Library/Logs/SteamFix.log
```

With `debug` on, the library accepts commands (answers go to the same log):

```sh
make tools                        # builds wins and sfcmd into build/tools
build/tools/sfcmd "helper:dump"   # activation policy, menu and windows of Steam Helper
build/tools/sfcmd "main:dump"     # the same for steam_osx
```

To clear the agent's back-off after a failed attempt:
`launchctl kickstart -k "gui/$(id -u)/local.steamfix.agent"`.

## Layout

```
src/steamfix.m       library loaded into steam_osx and Steam Helper
src/agent.swift      background agent
src/launcher.sh      the launcher's executable
scripts/build.sh     builds into build/
scripts/install.sh   builds and installs for the current user
scripts/uninstall.sh removes everything
tools/status.sh      status check (read-only)
tools/stagetest.sh   Stage Manager check (switches apps)
tools/build.sh       builds the tools into build/tools
tools/lib.sh         shared functions for the tools/ scripts
tools/wins.swift     lists Steam's windows
tools/sfcmd.swift    sends debug commands
```
