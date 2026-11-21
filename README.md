# Pomodoro Timer

A small macOS menu bar timer with a tomato icon. Pick a length from the menu (5 minutes to 8 hours) and it counts down in the menu bar, keeps the Mac (and optionally the display) awake while it runs, and plays a sound when it's done. It can start at login.

Two options keep the Mac awake with no session running: **Keep Awake on Battery**, and **Keep Awake on Wi-Fi** for the network saved with **Use Current Network as Wi-Fi Rule**. macOS only shows the Wi-Fi network name to apps with Location permission, so saving a network asks for it the first time.

## Build

Needs macOS 13 or later and Xcode's command line tools (Swift 6).

```sh
./build.sh        # builds "build/Pomodoro Timer.app"
./make_dmg.sh     # builds the app and packages "build/Pomodoro Timer.dmg"
```

The app is ad-hoc signed, so the first time you open a copy from another Mac, right-click it and choose Open.

`swift test` runs the update checker's tests. The version is in `VERSION`; the build number is the git commit count, and `build.sh` stamps both into the app.

## Updates

`scripts/release.sh [notes]` publishes the committed code: it builds the app, packs it in `Pomodoro-Timer-<version>-<build>.dmg`, puts that and `latest.json` in `~/Library/Application Support/Pomodoro Timer/releases` (or `$POMODORO_RELEASES`), keeps the last three images and tags the commit. Handoff runs it after every merge to `main`.

The app updates itself. At launch and every minute it looks in that folder; a newer build is copied, checked, and installed as soon as you're not using the app or the Mac has been idle for a minute, and the app reopens. The **Updates** section of the menu shows where it's at, with **Check for Updates…**, **Install and Restart** when a build is ready, and **Update Automatically** (on by default; off means it installs only when you choose Install and Restart).

## License

MIT. See [LICENSE](LICENSE).
