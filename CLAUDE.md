# Pomodoro Timer: notes for Claude

README.md is the user-facing how-to. This file is what a maintainer needs that the code doesn't show.
Work is tracked in Handoff, project **POMO** (Pomodoro Timer).

## Rules

- Keep README.md and this file in step with the change, in the same commit.
- Run `swift test` and `./build.sh` before committing.
- Don't run `scripts/release.sh` to try something out without a throwaway `POMODORO_RELEASES` (it publishes to the real releases folder and pushes a git tag). Handoff runs it after each merge.
- Keep the bundle id `com.jameshawkins.PomodoroTimer`: the updater refuses an image whose app has another one.

## How things work

- The app is menu-bar only (`LSUIElement`, `.accessory`). Everything is in the `NSMenu` built by `AppDelegate.buildMenu()`; `updateUI()` refreshes its state (also on every menu open). Errors go to the menu or `showError`'s alert; there are no windows.
- **Keep-awake rules**: `AwakeRule` and the pure matcher `AwakeRules.matchingAction` are in `AwakeRules.swift`; the "Rules…" window and its editor sheet are in `RulesWindow.swift`, and `AppDelegate` stores the rules as JSON under the defaults key `awakeRules`. `reevaluateRules()` runs on power-source changes and a 30 s poll (which also ends time windows), reads Wi-Fi only when an enabled rule needs it, and holds the assertion with the matching rule's own action (screen beats system); the global `keepDisplayAwake` is for sessions only. "Joined to any network" uses the Wi-Fi channel, which needs no Location permission; a named network needs the SSID, which does. `migrateRules()` turns the pre-rules keys `keepAwakeOnBattery` / `keepAwakeOnWiFi` / `keepAwakeSSID` into rules once (when `awakeRules` is absent) and deletes them.
- **Version and build**: `VERSION` is the version string; the build number is `git rev-list --count HEAD`. `build.sh` stamps both into the built app's Info.plist (`Resources/Info.plist`'s own values are placeholders). The updater compares the integer build only.
- **Updates**: `scripts/release.sh` builds the app, packs it in a plain `Pomodoro-Timer-<VERSION>-<commit count>.dmg` (not make_dmg.sh's) and puts it with `latest.json` in the releases folder: `POMODORO_RELEASES`, else `~/Library/Application Support/Pomodoro Timer/releases`. It refuses a dirty tree or a build already published, keeps the last three images and tags the commit `v<version>-<build>` (a failed push only warns). Handoff's after-merge step runs it in the `_release` checkout of `main`. The app (`ReleaseFolder`, `UpdateChecker` in `Sources/PomodoroTimerCore`; `Updater` in `Sources/PomodoroTimer/Updater.swift`) reads `latest.json` at launch and every minute, copies and verifies a newer build into `~/Library/Caches/Pomodoro Timer/Updates`, and installs it by itself when the app isn't frontmost (almost always, for a menu-bar app) or the Mac has been idle 60 s; "Update Automatically" (defaults key `updateAutomatically`, default on) off means only Install and Restart. A build whose install failed isn't retried on its own. The installer (`UpdateInstaller`) is ported from Read Receipts (itself from Photo Syncer): verify sha256, refuse a translocated app, mount, check bundle id/build/signature, swap with a detached helper script that keeps `<app>.previous` until the new one is in place and rolls back if the move fails, reopen. Its log is `install.log` in the caches folder. Only built apps update; `swift run` shows "Updates off".
- **Signing**: ad hoc (`codesign --sign -`), no Developer ID, not notarized. Ad hoc has no team ID, so the installer's same-team check is skipped. A first install on another Mac needs right-click › Open; the updater strips quarantine from the builds it installs.
- The feed is a local folder, so only this Mac (or one that sees the folder) updates. Other Macs would need a hosted feed and an HTTPS replacement for `ReleaseFolder`.
