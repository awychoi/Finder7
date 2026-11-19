import XCTest
@testable import SevenZipCore

final class UpdatePreconditionTests: XCTestCase {
    func testAppTranslocationIsRefused() {
        let bundle = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/1234/d/SevenZip.app")
        XCTAssertThrowsError(
            try EngineUpdateService.checkPreconditions(bundle: bundle, isArchiveOperationRunning: { false })
        ) { error in
            guard case EngineUpdateError.appTranslocated = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testArchiveOperationIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipPrecondition-\(UUID().uuidString)/SevenZip.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(
            try EngineUpdateService.checkPreconditions(bundle: root, isArchiveOperationRunning: { true })
        ) { error in
            guard case EngineUpdateError.archiveOperationRunning = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testReadOnlyBundleIsRefused() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipPrecondition-\(UUID().uuidString)", isDirectory: true)
        let bundle = parent.appendingPathComponent("SevenZip.app", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resources.path)
            try? FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: resources.path)
        XCTAssertThrowsError(
            try EngineUpdateService.checkPreconditions(bundle: bundle, isArchiveOperationRunning: { false })
        ) { error in
            guard case EngineUpdateError.bundleNotWritable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInterprocessLockRejectsASecondHolder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevenzip-lock-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try XCTUnwrap(InterprocessLock(url: url))
        XCTAssertNil(InterprocessLock(url: url))
        first.unlock()
        XCTAssertNotNil(InterprocessLock(url: url))
    }
}
