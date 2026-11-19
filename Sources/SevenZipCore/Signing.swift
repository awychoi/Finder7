import Foundation

/// Ad-hoc signing used by the build script and by self-update.
///
/// The engine lives in `Contents/Resources`, so replacing it invalidates the
/// bundle seal. After every mutation of `Contents/Resources` the engine is
/// signed first, then the bundle.
public enum EngineSigning {
    public static func adHocSignEngine(_ engine: URL) throws {
        try CommandRunner.runChecked(
            ToolPaths.codesign,
            arguments: ["--force", "--sign", "-", "--timestamp=none", engine.path],
            step: "signing 7zz"
        )
    }

    public static func adHocSignBundle(_ bundle: URL) throws {
        try CommandRunner.runChecked(
            ToolPaths.codesign,
            arguments: ["--force", "--deep", "--sign", "-", "--timestamp=none", bundle.path],
            step: "signing the app bundle"
        )
    }

    public static func verifyBundle(_ bundle: URL) throws {
        try CommandRunner.runChecked(
            ToolPaths.codesign,
            arguments: ["--verify", "--deep", "--strict", bundle.path],
            step: "verifying the app signature"
        )
    }
}
