import XCTest
@testable import SevenZipCore

final class EngineInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(engineVersion: String = "26.05") throws -> URL {
        let bundle = root.appendingPathComponent("SevenZip.app", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\necho \"7-Zip (z) \(engineVersion) (arm64)\"\n", to: resources.appendingPathComponent("7zz"))
        try DependencyManifest.write(
            appName: "SevenZip",
            appVersion: "0.1.0",
            engineVersion: engineVersion,
            to: resources.appendingPathComponent("homelab-app.json")
        )
        try Data("source-build\n".utf8).write(to: resources.appendingPathComponent("engine-provenance.txt"))
        return bundle
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func stagedEngine(_ text: String = "#!/bin/sh\necho new engine\n") throws -> URL {
        let url = root.appendingPathComponent("7zz.new")
        try writeExecutable(text, to: url)
        return url
    }

    private func hooks(failAt: InstallStep?) -> InstallationHooks {
        InstallationHooks(
            signEngine: { _ in },
            signBundle: { _ in },
            verifySignature: { _ in },
            journalURL: nil,
            failAt: failAt
        )
    }

    private func engineText(_ bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/Resources/7zz"), encoding: .utf8)
    }

    func testSuccessfulInstallKeepsPreviousEngineAndRewritesManifest() throws {
        let bundle = try makeBundle(engineVersion: "26.05")
        let result = try EngineInstaller.install(
            stagedEngine: try stagedEngine(),
            newManifest: DependencyManifest(appName: "SevenZip", appVersion: "0.1.0", engineVersion: "26.06"),
            bundle: bundle,
            hooks: hooks(failAt: nil)
        )

        XCTAssertEqual(result.appliedVersion, "26.06")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.previousEngineURL.path))
        XCTAssertTrue(try engineText(bundle).contains("new engine"))
        let manifestURL = bundle.appendingPathComponent("Contents/Resources/homelab-app.json")
        XCTAssertEqual(try DependencyManifest.read(from: manifestURL).engineVersion, "26.06")
        let provenance = try String(
            contentsOf: bundle.appendingPathComponent("Contents/Resources/engine-provenance.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(provenance, "official-binary\n")
    }

    func testFailureAtSigningRollsBackEngineManifestAndSignature() throws {
        let bundle = try makeBundle(engineVersion: "26.05")
        let oldEngine = try engineText(bundle)
        let manifestURL = bundle.appendingPathComponent("Contents/Resources/homelab-app.json")

        XCTAssertThrowsError(
            try EngineInstaller.install(
                stagedEngine: try stagedEngine(),
                newManifest: DependencyManifest(appName: "SevenZip", appVersion: "0.1.0", engineVersion: "26.06"),
                bundle: bundle,
                hooks: hooks(failAt: .signBundle)
            )
        ) { error in
            guard case EngineUpdateError.stepFailed(let step, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(step, InstallStep.signBundle.title)
        }

        XCTAssertEqual(try engineText(bundle), oldEngine)
        XCTAssertEqual(try DependencyManifest.read(from: manifestURL).engineVersion, "26.05")
        let provenance = try String(
            contentsOf: bundle.appendingPathComponent("Contents/Resources/engine-provenance.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(provenance, "source-build\n")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/7zz.previous").path)
        )
    }

    func testInjectedFailureAtEveryStepLeavesOldEngineIntact() throws {
        for step in [InstallStep.swap, .manifest, .signEngine, .verifySignature] {
            let bundle = try makeBundle(engineVersion: "26.05")
            let oldEngine = try engineText(bundle)
            XCTAssertThrowsError(
                try EngineInstaller.install(
                    stagedEngine: try stagedEngine(),
                    newManifest: DependencyManifest(appName: "SevenZip", appVersion: "0.1.0", engineVersion: "26.06"),
                    bundle: bundle,
                    hooks: hooks(failAt: step)
                ),
                "step \(step)"
            )
            XCTAssertEqual(try engineText(bundle), oldEngine, "engine changed after failure at \(step)")
            let manifestURL = bundle.appendingPathComponent("Contents/Resources/homelab-app.json")
            XCTAssertEqual(
                try DependencyManifest.read(from: manifestURL).engineVersion,
                "26.05",
                "manifest changed after failure at \(step)"
            )
        }
    }


    func testFailureDuringBackupStillReSignsTheBundle() throws {
        let bundle = try makeBundle(engineVersion: "26.05")
        var signedBundle = false
        let hooks = InstallationHooks(
            signEngine: { _ in },
            signBundle: { _ in signedBundle = true },
            verifySignature: { _ in },
            journalURL: nil,
            failAt: .backup
        )
        XCTAssertThrowsError(
            try EngineInstaller.install(
                stagedEngine: try stagedEngine(),
                newManifest: DependencyManifest(appName: "SevenZip", appVersion: "0.1.0", engineVersion: "26.06"),
                bundle: bundle,
                hooks: hooks
            )
        )
        XCTAssertTrue(signedBundle, "a pre-swap failure must re-sign the bundle")
    }

    func testInterruptedSwapIsRecoveredFromJournal() throws {
        let bundle = try makeBundle(engineVersion: "26.05")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let oldEngine = try engineText(bundle)
        try writeExecutable("#!/bin/sh\necho \"7-Zip (z) 26.06 (arm64)\"\n", to: resources.appendingPathComponent("7zz"))
        try Data("7zz.previous".utf8).write(to: resources.appendingPathComponent("7zz.previous"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: resources.appendingPathComponent("7zz.previous").path
        )
        // The backup file must be a runnable copy of the old engine for the
        // recovery test; replace it with the real previous script.
        try oldEngine.data(using: .utf8)!.write(to: resources.appendingPathComponent("7zz.previous"))
        let oldManifest = try String(contentsOf: resources.appendingPathComponent("homelab-app.json"), encoding: .utf8)
        let journalURL = root.appendingPathComponent("journal.json")
        try EngineUpdateJournal(
            bundlePath: bundle.standardizedFileURL.path,
            phase: .manifestWritten,
            previousVersion: "26.05",
            targetVersion: "26.06",
            previousManifest: oldManifest,
            previousProvenance: "source-build\n"
        ).write(to: journalURL)

        let outcome = EngineUpdateRecovery.recoverIfNeeded(
            bundle: bundle,
            journalURL: journalURL,
            hooks: hooks(failAt: nil)
        )
        XCTAssertEqual(outcome, .rolledBack(previousVersion: "26.05"))
        XCTAssertEqual(try engineText(bundle), oldEngine)
        XCTAssertEqual(
            try DependencyManifest.read(from: resources.appendingPathComponent("homelab-app.json")).engineVersion,
            "26.05"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }
}
