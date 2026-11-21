import CryptoKit
import Foundation
import Testing
@testable import PomodoroTimerCore

private let goodSHA = String(repeating: "a", count: 64)

private func release(build: String = "3", file: String = "Pomodoro-Timer-1.0.0-3.dmg", sha256: String = goodSHA) -> Data {
    Data(#"{"version":"1.0.0","build":\#(build),"file":"\#(file)","sha256":"\#(sha256)","publishedAt":"2026-11-21T10:00:00Z"}"#.utf8)
}

@Test func decodesAGoodRelease() throws {
    let info = try ReleaseInfo.decode(release())
    #expect(info.build == 3)
    #expect(info.file == "Pomodoro-Timer-1.0.0-3.dmg")
    #expect(info.publishedAt != nil)
}

@Test(arguments: ["0", "-1", "\"3\""])
func rejectsBadBuilds(build: String) {
    #expect(throws: UpdateError.self) { try ReleaseInfo.decode(release(build: build)) }
}

@Test(arguments: ["abc", String(repeating: "a", count: 63), String(repeating: "g", count: 64)])
func rejectsBadChecksums(sha256: String) {
    #expect(throws: UpdateError.self) { try ReleaseInfo.decode(release(sha256: sha256)) }
}

@Test(arguments: ["../evil.dmg", ".hidden.dmg", "app.zip", "a:b.dmg", "x.dmg?y", ".dmg"])
func rejectsUnsafeFileNames(file: String) {
    #expect(throws: UpdateError.self) { try ReleaseInfo.decode(release(file: file)) }
}

@Test func onlyAHigherBuildIsNewer() throws {
    let info = try ReleaseInfo.decode(release(build: "5"))
    #expect(info.isNewer(than: 4))
    #expect(!info.isNewer(than: 5))
    #expect(!info.isNewer(than: 6))
}

@Test func verifyChecksTheSHA256() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("pomodoro-verify-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    let data = Data("a disk image".utf8)
    try data.write(to: file)
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try UpdateChecker.verify(file, sha256: sha)
    try UpdateChecker.verify(file, sha256: sha.uppercased())
    #expect(throws: UpdateError.checksumMismatch("image.dmg")) {
        try UpdateChecker.verify(file, sha256: String(repeating: "0", count: 64), name: "image.dmg")
    }
}

@Test func updatesComeFromTheReleasesFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pomodoro-releases-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("releases"), staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let checker = UpdateChecker(source: ReleaseFolder(url: folder), currentBuild: 5, stagingDirectory: staging)
    #expect(try checker.newerRelease() == nil)  // nothing published yet

    let image = Data("not really a disk image".utf8)
    let sha = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
    try image.write(to: folder.appendingPathComponent("Pomodoro-Timer-1.0.0-6.dmg"))
    func publish(build: Int, sha256: String) throws {
        try release(build: "\(build)", file: "Pomodoro-Timer-1.0.0-6.dmg", sha256: sha256).write(to: folder.appendingPathComponent("latest.json"))
    }

    try publish(build: 5, sha256: sha)
    #expect(try checker.newerRelease() == nil)  // same build as the running app
    try publish(build: 6, sha256: sha)
    let found = try #require(try checker.newerRelease())
    #expect(try Data(contentsOf: checker.download(found)) == image)

    // A copy that doesn't match its checksum is refused and not kept.
    try publish(build: 6, sha256: String(repeating: "0", count: 64))
    checker.removeStaged()
    #expect(throws: UpdateError.self) { try checker.download(try #require(try checker.newerRelease())) }
    #expect(!FileManager.default.fileExists(atPath: checker.stagedImage(for: found).path))
}
