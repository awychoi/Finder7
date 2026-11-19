import Foundation

/// The small machine-readable version manifest consumed by Homelab Console.
///
/// `dependencies[].version` is the upstream 7-Zip release tag (digits and
/// dots), never the app's own version. The file is written at build time and
/// rewritten only after a verified in-app engine update.
public struct DependencyManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let engineRepo = "ip7z/7zip"
    public static let enginePath = "7zz"

    public struct App: Codable, Equatable, Sendable {
        public var name: String
        public var version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public struct Dependency: Codable, Equatable, Sendable {
        public var repo: String
        public var version: String
        public var path: String

        public init(repo: String, version: String, path: String) {
            self.repo = repo
            self.version = version
            self.path = path
        }
    }

    public var schema: Int
    public var app: App
    public var dependencies: [Dependency]

    public init(schema: Int = DependencyManifest.schemaVersion, app: App, dependencies: [Dependency]) {
        self.schema = schema
        self.app = app
        self.dependencies = dependencies
    }

    public init(appName: String, appVersion: String, engineVersion: String) {
        self.init(
            app: App(name: appName, version: appVersion),
            dependencies: [
                Dependency(
                    repo: DependencyManifest.engineRepo,
                    version: engineVersion,
                    path: DependencyManifest.enginePath
                )
            ]
        )
    }

    /// The 7-Zip version recorded for Homelab Console.
    public var engineVersion: String? {
        dependencies.first(where: { $0.repo == Self.engineRepo })?.version
    }

    public var engineDependency: Dependency? {
        dependencies.first(where: { $0.repo == Self.engineRepo })
    }

    // MARK: Validation

    public func validate() throws {
        guard schema == Self.schemaVersion else {
            throw DependencyManifestError.unsupportedSchema(schema)
        }
        guard !app.name.isEmpty, !app.version.isEmpty else {
            throw DependencyManifestError.missingAppVersion
        }
        guard let dependency = engineDependency else {
            throw DependencyManifestError.missingEngineDependency
        }
        guard EngineVersion(dependency.version) != nil else {
            throw DependencyManifestError.invalidEngineVersion(dependency.version)
        }
        guard dependency.path == Self.enginePath else {
            throw DependencyManifestError.unexpectedEnginePath(dependency.path)
        }
    }

    // MARK: Reading and writing

    public static func read(from url: URL) throws -> DependencyManifest {
        let data = try Data(contentsOf: url)
        do {
            let manifest = try JSONDecoder().decode(DependencyManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as DependencyManifestError {
            throw error
        } catch {
            throw DependencyManifestError.corrupt(url.lastPathComponent, error.localizedDescription)
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// Writes the manifest atomically so readers never observe a partial file.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try jsonData().write(to: url, options: [.atomic])
    }

    public static func write(appName: String, appVersion: String, engineVersion: String, to url: URL) throws {
        try DependencyManifest(
            appName: appName,
            appVersion: appVersion,
            engineVersion: engineVersion
        ).write(to: url)
    }
}

public enum DependencyManifestError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case missingAppVersion
    case missingEngineDependency
    case invalidEngineVersion(String)
    case unexpectedEnginePath(String)
    case corrupt(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            return "homelab-app.json uses unsupported schema \(schema); expected \(DependencyManifest.schemaVersion)."
        case .missingAppVersion:
            return "homelab-app.json is missing the app name or version."
        case .missingEngineDependency:
            return "homelab-app.json has no ip7z/7zip dependency."
        case .invalidEngineVersion(let version):
            return "homelab-app.json has an invalid 7-Zip version “\(version)”."
        case .unexpectedEnginePath(let path):
            return "homelab-app.json points at “\(path)” instead of \(DependencyManifest.enginePath)."
        case .corrupt(let name, let reason):
            return "Could not read \(name): \(reason)"
        }
    }
}
