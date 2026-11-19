import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
    public var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum CommandRunner {
    /// Runs a tool without a shell. The tools used here (lipo, codesign, tar,
    /// 7zz) produce small output, so draining both pipes before waiting is safe.
    @discardableResult
    public static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw EngineUpdateError.stepFailed(
                step: "launch \(URL(fileURLWithPath: executable).lastPathComponent)",
                reason: error.localizedDescription
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    @discardableResult
    public static func runChecked(
        _ executable: String,
        arguments: [String],
        step: String,
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        let result = try run(executable, arguments: arguments, environment: environment)
        guard result.succeeded else {
            let detail = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineUpdateError.stepFailed(
                step: step,
                reason: detail.isEmpty ? "exited with status \(result.status)" : detail
            )
        }
        return result
    }
}

// MARK: - Tool paths

public enum ToolPaths {
    public static let lipo = "/usr/bin/lipo"
    public static let codesign = "/usr/bin/codesign"
    public static let tar = "/usr/bin/tar"
    public static let ditto = "/usr/bin/ditto"
}
