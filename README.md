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

## License

MIT. See [LICENSE](LICENSE).
