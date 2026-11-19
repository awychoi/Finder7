import Foundation
import SevenZipCore

/// Headless entry points used by scripts and integration tests.
///
/// - `--dependency-versions` prints the bundled `homelab-app.json`.
/// - `--self-update --check [--from-dir DIR]` checks and prints JSON.
/// - `--self-update --apply [--from-dir DIR] [--tag TAG]` applies an update.
enum SelfUpdateCLI {
    static func printDependencyVersions() -> Int32 {
        var candidates = [
            Bundle.main.url(forResource: "homelab-app", withExtension: "json"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/homelab-app.json")
        ].compactMap { $0 }
        if let override = ProcessInfo.processInfo.environment["SEVENZIP_MANIFEST"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            FileHandle.standardError.write(Data("error: homelab-app.json is missing from the app bundle\n".utf8))
            return 1
        }
        do {
            let data = try Data(contentsOf: url)
            _ = try DependencyManifest.read(from: url)
            FileHandle.standardOutput.write(data)
            if data.last != 0x0A {
                FileHandle.standardOutput.write(Data([0x0A]))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func run(arguments: [String]) async -> Int32 {
        let check = arguments.contains("--check")
        let apply = arguments.contains("--apply")
        let fromDirectory = value(for: "--from-dir", in: arguments).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let tag = value(for: "--tag", in: arguments)

        guard check != apply else {
            FileHandle.standardError.write(Data("usage: --self-update (--check | --apply) [--from-dir DIR] [--tag TAG]\n".utf8))
            return 2
        }

        let service = EngineUpdateService()
        do {
            if check {
                let result: UpdateCheck
                if let fromDirectory {
                    result = try await service.checkForUpdate(fromDirectory: fromDirectory)
                } else {
                    result = try await service.checkForUpdate(force: true)
                }
                try printJSON(result)
                return result.updateAvailable ? 2 : 0
            }

            let result = try await service.downloadAndApply(
                tag: tag,
                fromDirectory: fromDirectory,
                isArchiveOperationRunning: { false }
            )
            let payload: [String: Any] = [
                "appliedVersion": result.appliedVersion,
                "manifest": result.manifestURL.path,
                "previous": result.previousEngineURL.path,
                "restartRequired": true
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
