import AppKit
import PomodoroTimerCore

/// The running app, when it's a built "Pomodoro Timer.app" (not `swift run`).
struct InstalledApp: Equatable {
    let bundleURL: URL
    let bundleID: String
    let version: String
    let build: Int

    var label: String { "\(version) (build \(build))" }

    static let current: InstalledApp? = {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", let bundleID = bundle.bundleIdentifier,
              let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return InstalledApp(bundleURL: bundle.bundleURL, bundleID: bundleID, version: version, build: build)
    }()
}

/// Release → update, the app's side of it. `scripts/release.sh` puts the disk image and
/// `latest.json` in the releases folder (`ReleaseFolder`). This reads it (at launch, every minute,
/// and on Check for Updates), copies and verifies a newer build, then installs it once nobody is using the
/// app, or on Install & Restart. Ported from Photo Syncer.
@MainActor
final class Updater {
    enum Status: Equatable {
        case notChecked, checking, upToDate
        case downloading(ReleaseInfo), ready(ReleaseInfo), installing(ReleaseInfo)
        case failed(String)
    }

    private(set) var status: Status = .notChecked { didSet { onChange?() } }
    private(set) var notice: String? { didSet { onChange?() } }
    private(set) var lastChecked: Date?
    /// Called when `status` or `notice` changes, so the menu can redraw while it's open.
    var onChange: (() -> Void)?

    let app: InstalledApp? = .current
    static let automaticInterval: TimeInterval = 60
    private var timer: Timer?
    private var generation = 0
    /// A build whose install failed: not tried again on its own, only from Install & Restart.
    private var skipBuild: Int?
    static let autoUpdateKey = "updateAutomatically"
    var autoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoUpdateKey) }
    }

    private var staging: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pomodoro Timer/Updates", isDirectory: true)
    }

    var readyRelease: ReleaseInfo? {
        if case .ready(let release) = status { return release }
        return nil
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func start() {
        guard app != nil else { return }
        switch UpdateInstaller.takeResult(in: staging) {
        case .failed:
            notice = "The last update couldn't be installed, so the previous version was kept (see \(UpdateInstaller.logURL(in: staging).path))."
            skipBuild = try? ReleaseFolder().latest()?.build
        default: break
        }
        if autoUpdate { check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.automaticInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.autoUpdate == true { self?.check() }
            }
        }
    }

    func check() {
        guard let app else { return }
        if case .installing = status { return }
        generation += 1
        let run = generation
        let waiting = readyRelease
        if waiting == nil { status = .checking }
        let checker = UpdateChecker(currentBuild: app.build, stagingDirectory: staging)
        Task {
            do {
                let release = try await Task.detached { try checker.newerRelease() }.value
                guard run == generation else { return }
                lastChecked = Date()
                guard let release else {
                    checker.removeStaged()
                    status = .upToDate
                    return
                }
                if release != waiting { status = .downloading(release) }
                _ = try await Task.detached { try checker.download(release) }.value
                guard run == generation else { return }
                checker.removeStaged(except: release)
                status = .ready(release)
                installIfAway(release)
            } catch {
                guard run == generation else { return }
                lastChecked = Date()
                if let waiting, FileManager.default.fileExists(atPath: checker.stagedImage(for: waiting).path) { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    func install() {
        guard let app, let release = readyRelease else { return }
        generation += 1
        status = .installing(release)
        notice = nil
        let staging = staging
        let image = staging.appendingPathComponent(release.file)
        Task {
            do {
                let payload = try await Task.detached {
                    try UpdateInstaller.prepare(image: image, release: release, replacing: app, in: staging)
                }.value
                try UpdateInstaller.handOff(payload: payload, replacing: app, in: staging)
                NSApp.terminate(nil)
            } catch {
                skipBuild = release.build
                status = .failed("Version \(release.label) couldn't be installed: \(error.localizedDescription)")
            }
        }
    }

    /// Installs on its own only while the app is in the background or nobody has touched the Mac
    /// for a minute, so the restart doesn't land in the middle of something. Otherwise the next
    /// minute's check tries again.
    private func installIfAway(_ release: ReleaseInfo) {
        guard autoUpdate, release.build != skipBuild else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if !NSApp.isActive || idle > 60 { install() }
    }
}

/// Replaces the running app with a downloaded build. The app can't overwrite itself while it
/// runs, so the swap is done by a small shell script that waits for the app to quit.
enum UpdateInstaller {
    enum Failure: Error, LocalizedError {
        case translocated
        case notWritable(String)
        case noApp
        case wrongBuild(found: String, expected: Int)
        case notNewer(Int)
        case badSignature(String)
        case differentSigner
        case tool(String, String)

        var errorDescription: String? {
            switch self {
            case .translocated:
                return "macOS is running Pomodoro Timer from a temporary, read-only place. Move it to your Applications folder, open it from there, and try again."
            case .notWritable(let folder):
                return "Pomodoro Timer can't change \(folder), where it's installed."
            case .noApp:
                return "the disk image doesn't contain Pomodoro Timer."
            case .wrongBuild(let found, let expected):
                return "the disk image contains build \(found), not the build \(expected) that was announced."
            case .notNewer(let build):
                return "the disk image contains build \(build), which isn't newer than this one."
            case .badSignature(let details):
                return "the new app's code signature doesn't check out (\(details))."
            case .differentSigner:
                return "the new app is signed by someone other than the signer of this one."
            case .tool(let name, let output):
                return "\(name) failed: \(output)"
            }
        }
    }

    enum Result: String {
        case installed, failed
    }

    static func logURL(in staging: URL) -> URL { staging.appendingPathComponent("install.log") }
    private static func resultURL(in staging: URL) -> URL { staging.appendingPathComponent("install-result") }
    private static func workDirectory(in staging: URL) -> URL { staging.appendingPathComponent("Install", isDirectory: true) }

    /// How the last install ended, if one ran since this was last asked. Also clears what an
    /// install leaves behind (the helper script, an unpacked app that was never installed).
    static func takeResult(in staging: URL) -> Result? {
        let files = FileManager.default
        let work = workDirectory(in: staging)
        if files.fileExists(atPath: work.path) {
            let mount = work.appendingPathComponent("mount", isDirectory: true)
            if ((try? files.contentsOfDirectory(atPath: mount.path)) ?? []).isEmpty == false { detach(mount) }
            try? files.removeItem(at: work)
        }
        let url = resultURL(in: staging)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? files.removeItem(at: url)
        return Result(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Unpacks the verified disk image and checks the app inside it: the same bundle id, the
    /// announced build, newer than this one, a valid code signature, and the same signing team
    /// when this app has one. Returns the unpacked app, ready for `handOff`. Blocking.
    static func prepare(image: URL, release: ReleaseInfo, replacing app: InstalledApp, in staging: URL) throws -> URL {
        let files = FileManager.default
        // Gatekeeper runs a quarantined app from a random read-only mount: there's nothing to replace.
        guard !app.bundleURL.path.contains("/AppTranslocation/") else { throw Failure.translocated }
        let parent = app.bundleURL.deletingLastPathComponent()
        guard files.isWritableFile(atPath: parent.path) else { throw Failure.notWritable(parent.path) }

        // The disk image has sat in the caches folder since it was checked; check it again.
        try UpdateChecker.verify(image, sha256: release.sha256)

        let work = workDirectory(in: staging)
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        if files.fileExists(atPath: mount.path) { _ = try? run("/usr/bin/hdiutil", "detach", mount.path, "-force") }
        try? files.removeItem(at: work)
        try files.createDirectory(at: mount, withIntermediateDirectories: true)

        try attach(image, at: mount)
        let payload = work.appendingPathComponent(app.bundleURL.lastPathComponent, isDirectory: true)
        do {
            defer { detach(mount) }
            let apps = try files.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
            guard let source = apps.first(where: { info($0)?["CFBundleIdentifier"] as? String == app.bundleID }) else {
                throw Failure.noApp
            }
            try run("/usr/bin/ditto", source.path, payload.path)
        }

        do {
            try check(payload, is: release, replacing: app)
        } catch {
            try? files.removeItem(at: payload)
            throw error
        }
        return payload
    }

    private static func check(_ payload: URL, is release: ReleaseInfo, replacing app: InstalledApp) throws {
        guard let info = info(payload), info["CFBundleIdentifier"] as? String == app.bundleID else { throw Failure.noApp }
        let found = info["CFBundleVersion"] as? String ?? "?"
        guard Int(found) == release.build else { throw Failure.wrongBuild(found: found, expected: release.build) }
        guard release.build > app.build else { throw Failure.notNewer(release.build) }
        do {
            try run("/usr/bin/codesign", "--verify", "--deep", "--strict", payload.path)
        } catch Failure.tool(_, let output) {
            throw Failure.badSignature(output)
        }
        // An ad hoc signature has no team, so there's nothing to compare; a real one must match.
        if let team = signingTeam(of: app.bundleURL), signingTeam(of: payload) != team { throw Failure.differentSigner }
    }

    /// Starts the helper that swaps the bundles once this process has quit. Call
    /// `NSApp.terminate` straight after.
    static func handOff(payload: URL, replacing app: InstalledApp, in staging: URL) throws {
        let script = workDirectory(in: staging).appendingPathComponent("install.sh")
        try helperScript.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: resultURL(in: staging))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup and "&" detach the helper, so it carries on when the app (its parent) is gone.
        process.arguments = [
            "-c", #"/usr/bin/nohup /bin/sh "$0" "$@" >/dev/null 2>&1 &"#, script.path,
            String(ProcessInfo.processInfo.processIdentifier), payload.path, app.bundleURL.path,
            logURL(in: staging).path, resultURL(in: staging).path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// The helper. The new app is copied next to the installed one first, so the installed app
    /// is only touched by two renames; if the second fails, the first is undone.
    static let helperScript = #"""
        #!/bin/sh
        # Pomodoro Timer's update helper: puts a new build in place once the app has quit, then
        # opens it. Written and started by the app (Updater.swift); never run by hand.
        #   $1  the app's process id       $2  the new app, already checked by the app
        #   $3  the installed app          $4  a log of what happened
        #   $5  where to leave "installed" or "failed" for the app to read when it reopens
        pid="$1"
        new="$2"
        target="$3"
        log="$4"
        result="$5"
        case "$target" in
            /*.app) ;;
            *) exit 64 ;;
        esac
        [ -d "$new" ] && [ -n "$log" ] && [ -n "$result" ] || exit 64
        incoming="$target.incoming"
        backup="$target.previous"

        : >"$log"
        exec >>"$log" 2>&1
        say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

        reopen() {
            # A throwaway releases folder (POMODORO_RELEASES) carries over; `open` wouldn't pass it on.
            if [ -n "${POMODORO_RELEASES:-}" ]; then
                /usr/bin/open --env "POMODORO_RELEASES=$POMODORO_RELEASES" "$target"
            else
                /usr/bin/open "$target"
            fi
        }

        give_up() {
            say "$1"
            echo "failed" >"$result"
            rm -rf "$incoming"
        }

        say "Waiting for Pomodoro Timer (process $pid) to quit"
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            waited=$((waited + 1))
            if [ "$waited" -gt 300 ]; then
                give_up "It was still running after a minute; nothing was changed."
                exit 1
            fi
            sleep 0.2
        done

        rm -rf "$incoming" "$backup"
        if ! /usr/bin/ditto "$new" "$incoming" || ! /usr/bin/codesign --verify --deep --strict "$incoming"; then
            give_up "Couldn't copy the new version next to the installed one; nothing was changed."
            reopen
            exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$incoming" 2>/dev/null

        if ! mv "$target" "$backup"; then
            give_up "Couldn't move the installed version aside; nothing was changed."
            reopen
            exit 1
        fi

        if mv "$incoming" "$target"; then
            touch "$target"
            rm -rf "$backup" "$new"
            say "Installed the new version at $target"
            echo "installed" >"$result"
            status=0
        else
            say "Couldn't move the new version into place; putting the previous one back."
            if mv "$backup" "$target"; then
                give_up "The previous version is back in place."
            else
                give_up "Couldn't put it back either: the previous version is at $backup"
            fi
            status=1
        fi

        reopen
        exit "$status"

        """#

    // MARK: Tools

    private static func info(_ app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    /// The Team ID an app is signed with; nil for ad hoc and self-signed apps.
    private static func signingTeam(of app: URL) -> String? {
        guard let output = try? run("/usr/bin/codesign", "-dv", "--verbose=2", app.path) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let team = String(line.dropFirst("TeamIdentifier=".count))
            return team == "not set" ? nil : team
        }
        return nil
    }

    /// Mounts a disk image where Finder won't show it. `hdiutil attach` works on every macOS
    /// the app supports but is deprecated from macOS 27, which points at `diskutil image`
    /// instead; that's the fallback for when hdiutil stops doing it.
    private static func attach(_ image: URL, at mount: URL) throws {
        do {
            try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path)
        } catch {
            guard (try? run("/usr/sbin/diskutil", "image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mount.path, image.path)) != nil else {
                throw error
            }
        }
    }

    private static func detach(_ mount: URL) {
        if (try? run("/usr/bin/hdiutil", "detach", mount.path)) != nil { return }
        if (try? run("/usr/sbin/diskutil", "eject", mount.path)) != nil { return }
        _ = try? run("/usr/bin/hdiutil", "detach", mount.path, "-force")
    }

    /// Runs a tool and returns what it printed; throws with that output if it fails. The output
    /// goes through a file, not a pipe: hdiutil leaves a helper running that would hold a pipe
    /// open, and reading it to the end would wait on that helper.
    @discardableResult
    private static func run(_ tool: String, _ arguments: String...) throws -> String {
        let files = FileManager.default
        let capture = files.temporaryDirectory.appendingPathComponent("pomodoro-timer-update-\(UUID().uuidString).txt")
        files.createFile(atPath: capture.path, contents: nil)
        defer { try? files.removeItem(at: capture) }
        let output = try FileHandle(forWritingTo: capture)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let printed = ((try? String(contentsOf: capture, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure.tool(URL(fileURLWithPath: tool).lastPathComponent, printed.isEmpty ? "exit \(process.terminationStatus)" : printed)
        }
        return printed
    }
}
