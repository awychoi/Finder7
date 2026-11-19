import XCTest
@testable import SevenZipCore

final class EngineVersionTests: XCTestCase {
    func testNumericOrdering() throws {
        let v2606 = try XCTUnwrap(EngineVersion("26.06"))
        let v2607 = try XCTUnwrap(EngineVersion("26.07"))
        let v2610 = try XCTUnwrap(EngineVersion("26.10"))
        let v269 = try XCTUnwrap(EngineVersion("26.9"))
        let v27 = try XCTUnwrap(EngineVersion("27"))
        let v2700 = try XCTUnwrap(EngineVersion("27.0"))

        XCTAssertLessThan(v2606, v2607)
        XCTAssertLessThan(v269, v2610)
        XCTAssertLessThan(v2610, v27)
        XCTAssertEqual(v27, v2700)
        XCTAssertEqual(v2606, try XCTUnwrap(EngineVersion("26.6")))
        XCTAssertFalse(v2607 < v2606)
        XCTAssertTrue(EngineVersion.isNewer("26.06", than: "26.05"))
        XCTAssertFalse(EngineVersion.isNewer("26.05", than: "26.06"))
        XCTAssertFalse(EngineVersion.isNewer("26.06", than: "26.06"))
    }

    func testInvalidVersions() {
        XCTAssertNil(EngineVersion(""))
        XCTAssertNil(EngineVersion("26."))
        XCTAssertNil(EngineVersion(".26"))
        XCTAssertNil(EngineVersion("26.06-beta"))
        XCTAssertNil(EngineVersion("seven"))
        XCTAssertEqual(EngineVersion("v26.06")?.raw, "26.06")
    }

    func testAssetNameMapping() throws {
        let version = try XCTUnwrap(EngineVersion("26.06"))
        XCTAssertEqual(version.assetCode, "2606")
        XCTAssertEqual(version.assetNames.arm64, "7z2606-mac.tar.xz")
        XCTAssertEqual(version.assetNames.x86_64, "7z2606-mac-x64.tar.xz")
        XCTAssertEqual(
            EngineAssetMapping.assetURL(tag: "26.06", name: "7z2606-mac.tar.xz")?.absoluteString,
            "https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac.tar.xz"
        )
        XCTAssertNil(EngineAssetMapping.assetURL(tag: "26.06", name: "7z2606-mac-arm64.tar.xz"))
        XCTAssertEqual(EngineAssetMapping.tag(fromAssetName: "7z2606-mac.tar.xz"), "26.06")
        XCTAssertEqual(EngineAssetMapping.tag(fromAssetName: "7z2606-mac-x64.tar.xz"), "26.06")
        XCTAssertNil(EngineAssetMapping.tag(fromAssetName: "7z2606-linux.tar.xz"))
    }

    func testUpdateCheckEvaluation() throws {
        let release = GitHubRelease(
            tagName: "26.06",
            publishedAt: "2026-11-07T11:45:33Z",
            htmlURL: "https://github.com/ip7z/7zip/releases/tag/26.06",
            assets: [
                GitHubRelease.Asset(
                    name: "7z2606-mac.tar.xz",
                    browserDownloadURL: URL(string: "https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac.tar.xz")!,
                    size: 1,
                    digest: "sha256:" + String(repeating: "a", count: 64),
                    contentType: nil
                )
            ]
        )
        let check = try UpdateCheck.evaluate(
            installedVersion: "26.05",
            release: release,
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(check.updateAvailable)
        XCTAssertEqual(check.latestVersion, "26.06")
        XCTAssertEqual(check.assetNames, ["7z2606-mac.tar.xz"])
    }
}
