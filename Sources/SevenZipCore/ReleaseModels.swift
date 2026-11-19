import Foundation

// MARK: - GitHub release metadata

/// The subset of the GitHub release API used by the updater.
public struct GitHubRelease: Codable, Sendable {
    public struct Asset: Codable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int64?
        public let digest: String?
        public let contentType: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
            case contentType = "content_type"
        }

        public init(name: String, browserDownloadURL: URL, size: Int64?, digest: String?, contentType: String?) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
            self.size = size
            self.digest = digest
            self.contentType = contentType
        }

        /// `sha256:...` (the GitHub asset digest format) without the prefix.
        public var sha256: String? {
            guard let digest else { return nil }
            let lower = digest.lowercased()
            guard lower.hasPrefix("sha256:") else { return nil }
            let value = String(digest.dropFirst("sha256:".count)).lowercased()
            return value.count == 64 ? value : nil
        }
    }

    public let tagName: String
    public let publishedAt: String?
    public let htmlURL: String?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case htmlURL = "html_url"
        case assets
    }

    public init(tagName: String, publishedAt: String?, htmlURL: String?, assets: [Asset]) {
        self.tagName = tagName
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
        self.assets = assets
    }

    public func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }

    public var version: EngineVersion? { EngineVersion(tagName) }
}

// MARK: - Update check

public struct UpdateCheck: Codable, Sendable, Equatable {
    public let installedVersion: String
    public let latestVersion: String
    public let updateAvailable: Bool
    public let checkedAt: Date
    public let releaseURL: String?
    public let publishedAt: String?
    public let assetNames: [String]

    public init(
        installedVersion: String,
        latestVersion: String,
        updateAvailable: Bool,
        checkedAt: Date,
        releaseURL: String?,
        publishedAt: String?,
        assetNames: [String]
    ) {
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.checkedAt = checkedAt
        self.releaseURL = releaseURL
        self.publishedAt = publishedAt
        self.assetNames = assetNames
    }

    public static func evaluate(installedVersion: String, release: GitHubRelease, now: Date = Date()) throws -> UpdateCheck {
        guard let latest = release.version else {
            throw EngineUpdateError.invalidRelease("GitHub returned an invalid release tag “\(release.tagName)”.")
        }
        guard EngineVersion(installedVersion) != nil else {
            throw EngineUpdateError.invalidInstalledVersion(installedVersion)
        }
        let assetNames = [latest.assetNames.arm64, latest.assetNames.x86_64]
        guard release.asset(named: latest.assetNames.arm64) != nil else {
            throw EngineUpdateError.noMacOSAsset(tag: latest.raw, missing: latest.assetNames.arm64)
        }
        return UpdateCheck(
            installedVersion: installedVersion,
            latestVersion: latest.raw,
            updateAvailable: latest > (EngineVersion(installedVersion) ?? latest),
            checkedAt: now,
            releaseURL: release.htmlURL,
            publishedAt: release.publishedAt,
            assetNames: assetNames.filter { release.asset(named: $0) != nil }
        )
    }
}

// MARK: - Progress and results

public struct UpdateProgress: Sendable {
    public enum Phase: String, Sendable {
        case downloading
        case verifying
        case staging
        case smokeTesting
        case installing
        case signing
        case manifest
        case finished
    }

    public let phase: Phase
    public let fraction: Double
    public let message: String

    public init(phase: Phase, fraction: Double, message: String) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
    }
}

public struct ApplyResult: Sendable {
    public let appliedVersion: String
    public let previousEngineURL: URL
    public let manifestURL: URL
    public let wasRolledBack: Bool

    public init(appliedVersion: String, previousEngineURL: URL, manifestURL: URL, wasRolledBack: Bool = false) {
        self.appliedVersion = appliedVersion
        self.previousEngineURL = previousEngineURL
        self.manifestURL = manifestURL
        self.wasRolledBack = wasRolledBack
    }
}

// MARK: - Errors

public enum EngineUpdateError: LocalizedError {
    case offline(String)
    case rateLimited(until: Date?, detail: String)
    case httpStatus(Int, String)
    case invalidRelease(String)
    case invalidInstalledVersion(String)
    case manifestMissing(String)
    case noMacOSAsset(tag: String, missing: String)
    case missingDigest(String)
    case downloadFailed(String, String)
    case sizeMismatch(String, expected: Int64, actual: Int64)
    case checksumMismatch(String, expected: String, actual: String)
    case extractionFailed(String, String)
    case missingArchiveMember(asset: String, member: String)
    case wrongArchitecture(asset: String, expected: String, actual: String)
    case universalEngineRequired(actual: String)
    case bannerMismatch(expected: String, actual: String)
    case smokeTestFailed(String)
    case appTranslocated(String)
    case bundleNotWritable(String)
    case archiveOperationRunning
    case updateInProgress
    case cancelled
    case rollbackFailed(step: String, reason: String, rollbackReason: String)
    case stepFailed(step: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .offline(let detail):
            return "Could not reach GitHub. Check your internet connection and try again.\n\n\(detail)"
        case .rateLimited(let until, let detail):
            let retry = until.map { " Try again after \(Self.dateFormatter.string(from: $0))." } ?? ""
            return "GitHub’s release API rate limit has been reached.\(retry)\n\n\(detail)"
        case .httpStatus(let status, let detail):
            return "GitHub returned HTTP \(status).\n\n\(detail)"
        case .invalidRelease(let detail):
            return "The latest GitHub release is not usable: \(detail)"
        case .invalidInstalledVersion(let version):
            return "The installed engine version “\(version)” is invalid. Rebuild the app with Scripts/build-app.sh."
        case .manifestMissing(let path):
            return "The app is missing \(path). Rebuild it with Scripts/build-app.sh before using self-update."
        case .noMacOSAsset(let tag, let missing):
            return "7-Zip \(tag) does not publish the macOS asset \(missing), so it cannot be installed as a universal engine."
        case .missingDigest(let asset):
            return "GitHub did not publish a SHA-256 digest for \(asset); refusing to install an unverified engine."
        case .downloadFailed(let asset, let reason):
            return "Could not download \(asset).\n\n\(reason)"
        case .sizeMismatch(let asset, let expected, let actual):
            return "\(asset) is \(actual) bytes; GitHub reported \(expected). The download may be truncated."
        case .checksumMismatch(let asset, let expected, let actual):
            return "\(asset) failed SHA-256 verification (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .extractionFailed(let asset, let reason):
            return "Could not extract \(asset).\n\n\(reason)"
        case .missingArchiveMember(let asset, let member):
            return "\(asset) does not contain \(member)."
        case .wrongArchitecture(let asset, let expected, let actual):
            return "\(asset) contains \(actual.isEmpty ? "no recognized architecture" : actual); expected \(expected)."
        case .universalEngineRequired(let actual):
            return "The downloaded engine is not universal (architectures: \(actual.isEmpty ? "none" : actual)). Refusing to install it."
        case .bannerMismatch(let expected, let actual):
            return "The downloaded 7zz reports “\(actual)” but the release is \(expected). Refusing to install it."
        case .smokeTestFailed(let detail):
            return "The new 7zz failed its smoke test. The installed engine was not changed.\n\n\(detail)"
        case .appTranslocated(let path):
            return """
            SevenZip is running from App Translocation at \(path), so macOS will not let it update itself.
            Move SevenZip.app to Applications (or another permanent folder), open it from there, and try again.
            """
        case .bundleNotWritable(let path):
            return "The app bundle is not writable at \(path). Move it to a writable location and try again."
        case .archiveOperationRunning:
            return "An archive operation is running. Finish or cancel it before updating the engine."
        case .updateInProgress:
            return "An engine update is already in progress."
        case .cancelled:
            return "The update was cancelled. The installed engine was not changed."
        case .rollbackFailed(let step, let reason, let rollbackReason):
            return "The engine update failed at \(step): \(reason)\n\nRollback also failed: \(rollbackReason). Reinstall SevenZip from a known-good build."
        case .stepFailed(let step, let reason):
            return "Engine update failed at \(step).\n\n\(reason)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
