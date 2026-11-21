import CryptoKit
import Foundation

/// A published build, as `latest.json` in the releases folder describes it:
///
///     { "version": "1.0.0", "build": 42, "file": "Pomodoro-Timer-1.0.0-42.dmg",
///       "sha256": "…64 hex digits…", "publishedAt": "2026-01-02T03:04:05Z", "notes": "…" }
///
/// `scripts/release.sh` writes it beside the disk image.
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var file: String
    public var sha256: String
    public var publishedAt: Date?
    public var notes: String?

    public var label: String { "\(version) (build \(build))" }
    public func isNewer(than build: Int) -> Bool { self.build > build }

    /// Reads `latest.json`, refusing anything the updater shouldn't act on.
    public static func decode(_ data: Data) throws -> ReleaseInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let release = try? decoder.decode(ReleaseInfo.self, from: data) else {
            throw UpdateError.malformed("latest.json isn't valid.")
        }
        guard release.build > 0 else { throw UpdateError.malformed("its build number isn't positive.") }
        guard release.sha256.count == 64, release.sha256.allSatisfy(\.isHexDigit) else {
            throw UpdateError.malformed("its sha256 isn't 64 hex digits.")
        }
        guard isSafeFileName(release.file) else { throw UpdateError.malformed("its file isn't a bare .dmg name.") }
        return release
    }

    static func isSafeFileName(_ name: String) -> Bool {
        name.count > 4 && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":") && !name.contains("\0")
            && !name.contains("?") && !name.contains("#") && name.lowercased().hasSuffix(".dmg")
    }
}

public enum UpdateError: Error, LocalizedError, Equatable, Sendable {
    case malformed(String)
    case checksumMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let why): return "The latest release can't be used: \(why)"
        case .checksumMismatch(let file): return "\(file) doesn't match its published checksum, so it wasn't kept."
        }
    }
}

/// Releases in a folder on this Mac: `latest.json` and the disk images it names.
/// `scripts/release.sh` puts them there; Handoff runs it after each merge.
public struct ReleaseFolder: Sendable {
    /// `POMODORO_RELEASES`, else `~/Library/Application Support/Pomodoro Timer/releases`. release.sh picks the same.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["POMODORO_RELEASES"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomodoro Timer/releases", isDirectory: true)
    }

    public let url: URL

    public init(url: URL = ReleaseFolder.defaultURL) { self.url = url }

    /// The newest release, or nil when nothing has been published yet.
    public func latest() throws -> ReleaseInfo? {
        let file = url.appendingPathComponent("latest.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try ReleaseInfo.decode(Data(contentsOf: file))
    }

    public func fetch(_ release: ReleaseInfo, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url.appendingPathComponent(release.file), to: destination)
    }
}

/// Finds a newer release and keeps a verified copy of its disk image ready to install.
public struct UpdateChecker: Sendable {
    public let source: ReleaseFolder
    public let currentBuild: Int
    public let stagingDirectory: URL

    public init(source: ReleaseFolder = ReleaseFolder(), currentBuild: Int, stagingDirectory: URL) {
        self.source = source
        self.currentBuild = currentBuild
        self.stagingDirectory = stagingDirectory
    }

    public func newerRelease() throws -> ReleaseInfo? {
        guard let release = try source.latest() else { return nil }
        return release.isNewer(than: currentBuild) ? release : nil
    }

    public func stagedImage(for release: ReleaseInfo) -> URL { stagingDirectory.appendingPathComponent(release.file) }

    /// A verified copy of the release's disk image; a copy that doesn't match is deleted, never kept.
    public func download(_ release: ReleaseInfo) throws -> URL {
        let staged = stagedImage(for: release)
        let files = FileManager.default
        if files.fileExists(atPath: staged.path), (try? Self.verify(staged, sha256: release.sha256)) != nil { return staged }
        try? files.removeItem(at: staged)
        try files.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let partial = stagingDirectory.appendingPathComponent(release.file + ".partial")
        defer { try? files.removeItem(at: partial) }
        try source.fetch(release, to: partial)
        try Self.verify(partial, sha256: release.sha256, name: release.file)
        try files.moveItem(at: partial, to: staged)
        return staged
    }

    public static func verify(_ file: URL, sha256 expected: String, name: String? = nil) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError.checksumMismatch(name ?? file.lastPathComponent) }
    }

    public func removeStaged(except keep: ReleaseInfo? = nil) {
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        where (name.hasSuffix(".dmg") || name.hasSuffix(".partial")) && name != keep?.file {
            try? files.removeItem(at: stagingDirectory.appendingPathComponent(name))
        }
    }
}
