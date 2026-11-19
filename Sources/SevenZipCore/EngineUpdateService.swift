import Foundation

/// Network + filesystem orchestration for checking and applying a 7-Zip engine
/// update. The GUI controller and the headless `--self-update` flags share this
/// service so both follow exactly the same verification path.
public actor EngineUpdateService {
    public static let shared = EngineUpdateService()

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/ip7z/7zip/releases/latest"
    )!
    private static let cacheLifetime: TimeInterval = 15 * 60

    private let bundle: URL
    private let cache: UpdateCache
    private let session: URLSession
    private let downloader: AssetDownloader
    private let now: @Sendable () -> Date
    private var isApplying = false

    public init(
        bundle: URL = Bundle.main.bundleURL,
        cache: UpdateCache = UpdateCache(),
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bundle = bundle
        self.cache = cache
        self.now = now
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.httpAdditionalHeaders = [
                "Accept": "application/vnd.github+json",
                "User-Agent": "Finder7-update-check"
            ]
            self.session = URLSession(configuration: configuration)
        }
        self.downloader = AssetDownloader(session: session)
    }

    // MARK: - Installed engine

    public var installedManifest: DependencyManifest {
        get throws {
            let url = bundle
                .appendingPathComponent("Contents/Resources", isDirectory: true)
                .appendingPathComponent("homelab-app.json")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EngineUpdateError.manifestMissing("Contents/Resources/homelab-app.json")
            }
            return try DependencyManifest.read(from: url)
        }
    }

    public var lastCheckDate: Date? {
        cache.lastCheckDate
    }

    // MARK: - Checking

    /// Checks the latest GitHub release. Results are cached for 15 minutes.
    /// `force` bypasses the cache but still respects GitHub's rate-limit
    /// backoff.
    public func checkForUpdate(force: Bool = false) async throws -> UpdateCheck {
        let manifest = try installedManifest
        guard let installed = manifest.engineVersion else {
            throw EngineUpdateError.manifestMissing("ip7z/7zip in homelab-app.json")
        }
        let now = self.now()

        if !force, let cached = cache.cachedState(
            installedVersion: installed,
            maxAge: Self.cacheLifetime,
            now: now
        ) {
            return cached
        }

        if let until = cache.rateLimitedUntil, now < until {
            throw EngineUpdateError.rateLimited(until: until, detail: "The last check hit GitHub's rate limit.")
        }

        let release = try await fetchRelease(tag: nil, etag: cache.etag)
        let check = try UpdateCheck.evaluate(installedVersion: installed, release: release, now: now)
        cache.save(release: release, installedVersion: installed, checkedAt: now, etag: cache.etag)
        return check
    }

    /// Offline check against a fixture directory (`--from-dir`).
    public func checkForUpdate(fromDirectory directory: URL) throws -> UpdateCheck {
        let manifest = try installedManifest
        guard let installed = manifest.engineVersion else {
            throw EngineUpdateError.manifestMissing("ip7z/7zip in homelab-app.json")
        }
        let release = try loadLocalRelease(directory: directory, requestedTag: nil)
        let now = self.now()
        cache.lastCheckDate = now
        return try UpdateCheck.evaluate(installedVersion: installed, release: release, now: now)
    }

    // MARK: - Applying

    public func downloadAndApply(
        tag requestedTag: String?,
        fromDirectory directory: URL?,
        isArchiveOperationRunning: @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }
    ) async throws -> ApplyResult {
        guard !isApplying else { throw EngineUpdateError.updateInProgress }
        guard let processLock = InterprocessLock() else {
            throw EngineUpdateError.updateInProgress
        }
        isApplying = true
        defer {
            processLock.unlock()
            isApplying = false
        }

        try Task.checkCancellation()
        try Self.checkPreconditions(bundle: bundle, isArchiveOperationRunning: isArchiveOperationRunning)

        switch EngineUpdateRecovery.recoverIfNeeded(bundle: bundle) {
        case .failed(let reason):
            throw EngineUpdateError.stepFailed(step: "recovering an interrupted update", reason: reason)
        case .none, .completed, .rolledBack:
            break
        }

        let manifest = try installedManifest
        guard let installed = manifest.engineVersion else {
            throw EngineUpdateError.manifestMissing("ip7z/7zip in homelab-app.json")
        }

        let release: GitHubRelease
        if let directory {
            release = try loadLocalRelease(directory: directory, requestedTag: requestedTag)
        } else {
            release = try await fetchRelease(tag: requestedTag, etag: nil)
        }
        guard let target = release.version else {
            throw EngineUpdateError.invalidRelease("The release tag is not a valid 7-Zip version.")
        }
        if let requestedTag, requestedTag != target.raw {
            throw EngineUpdateError.invalidRelease(
                "Requested \(requestedTag), but the release metadata is for \(target.raw)."
            )
        }

        let names = target.assetNames
        guard let armAsset = release.asset(named: names.arm64) else {
            throw EngineUpdateError.noMacOSAsset(tag: target.raw, missing: names.arm64)
        }
        let x64Asset = release.asset(named: names.x86_64)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder7-engine-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress(UpdateProgress(phase: .downloading, fraction: 0.02, message: "Downloading 7zz \(target.raw)…"))
        let armFile = work.appendingPathComponent(armAsset.name)
        try await obtain(armAsset, to: armFile, requireDigest: directory == nil) { fraction in
            progress(UpdateProgress(
                phase: .downloading,
                fraction: x64Asset == nil ? 0.02 + fraction * 0.50 : 0.02 + fraction * 0.30,
                message: "Downloading \(armAsset.name)…"
            ))
        }
        try Task.checkCancellation()

        var x64File: URL?
        if let x64Asset {
            let file = work.appendingPathComponent(x64Asset.name)
            try await obtain(x64Asset, to: file, requireDigest: directory == nil) { fraction in
                progress(UpdateProgress(
                    phase: .downloading,
                    fraction: 0.32 + fraction * 0.22,
                    message: "Downloading \(x64Asset.name)…"
                ))
            }
            x64File = file
            try Task.checkCancellation()
        }

        progress(UpdateProgress(phase: .verifying, fraction: 0.58, message: "Verifying the download…"))
        let armExtract = work.appendingPathComponent("arm64", isDirectory: true)
        let armBinary = try extract(armAsset, from: armFile, into: armExtract)
        let armArchs = try architectures(of: armBinary)
        guard armArchs.contains(EngineAssetArchitecture.arm64.lipoName) else {
            throw EngineUpdateError.wrongArchitecture(
                asset: armAsset.name,
                expected: EngineAssetArchitecture.arm64.lipoName,
                actual: armArchs.sorted().joined(separator: " ")
            )
        }

        var x64Binary: URL?
        if let x64Asset, let x64File {
            let x64Extract = work.appendingPathComponent("x86_64", isDirectory: true)
            let binary = try extract(x64Asset, from: x64File, into: x64Extract)
            let archs = try architectures(of: binary)
            guard archs.contains(EngineAssetArchitecture.x86_64.lipoName) else {
                throw EngineUpdateError.wrongArchitecture(
                    asset: x64Asset.name,
                    expected: EngineAssetArchitecture.x86_64.lipoName,
                    actual: archs.sorted().joined(separator: " ")
                )
            }
            x64Binary = binary
        }

        progress(UpdateProgress(phase: .verifying, fraction: 0.66, message: "Building the universal engine…"))
        let universal = work.appendingPathComponent("7zz.universal")
        if armArchs.contains(EngineAssetArchitecture.x86_64.lipoName) {
            // Older releases ship one universal archive; 26.06+ splits them.
            try FileManager.default.copyItem(at: armBinary, to: universal)
        } else if let x64Binary {
            try CommandRunner.runChecked(
                ToolPaths.lipo,
                arguments: ["-create", "-output", universal.path, armBinary.path, x64Binary.path],
                step: "combining arm64 and x86_64 with lipo"
            )
        } else {
            throw EngineUpdateError.universalEngineRequired(actual: armArchs.sorted().joined(separator: " "))
        }
        let universalArchs = try architectures(of: universal)
        guard universalArchs.contains(EngineAssetArchitecture.arm64.lipoName),
              universalArchs.contains(EngineAssetArchitecture.x86_64.lipoName)
        else {
            throw EngineUpdateError.universalEngineRequired(actual: universalArchs.sorted().joined(separator: " "))
        }

        progress(UpdateProgress(phase: .staging, fraction: 0.70, message: "Staging 7zz.new…"))
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let staged = resources.appendingPathComponent("7zz.new")
        let thisManifestURL = resources.appendingPathComponent("homelab-app.json")
        let thisProvenanceURL = resources.appendingPathComponent("engine-provenance.txt")
        let previousManifest = (try? Data(contentsOf: thisManifestURL)).flatMap { String(data: $0, encoding: .utf8) }
        let previousProvenance = (try? Data(contentsOf: thisProvenanceURL)).flatMap { String(data: $0, encoding: .utf8) }
        let stagingJournal = EngineUpdateJournal(
            bundlePath: bundle.standardizedFileURL.path,
            previousVersion: installed,
            targetVersion: target.raw,
            previousManifest: previousManifest,
            previousProvenance: previousProvenance
        )
        try stagingJournal.write()
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.copyItem(at: universal, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            // lipo invalidates the linker signature; sign the staged slice so
            // macOS will execute it for the banner and smoke test.
            try EngineSigning.adHocSignEngine(staged)
            try verifyBanner(of: staged, expected: target)
            progress(UpdateProgress(phase: .smokeTesting, fraction: 0.78, message: "Smoke-testing the new engine…"))
            try smokeTest(binary: staged)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            try? EngineSigning.adHocSignBundle(bundle)
            EngineUpdateJournal.remove()
            if let updateError = error as? EngineUpdateError { throw updateError }
            throw EngineUpdateError.smokeTestFailed(error.localizedDescription)
        }

        let newManifest = DependencyManifest(
            appName: manifest.app.name,
            appVersion: manifest.app.version,
            engineVersion: target.raw
        )
        progress(UpdateProgress(phase: .installing, fraction: 0.84, message: "Installing 7zz \(target.raw)…"))
        do {
            let result = try EngineInstaller.install(
                stagedEngine: staged,
                newManifest: newManifest,
                bundle: bundle
            )
            cache.clear()
            cache.lastCheckDate = now()
            progress(UpdateProgress(phase: .finished, fraction: 1, message: "Updated to 7-Zip \(target.raw)."))
            return result
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    // MARK: - Preconditions

    public static func checkPreconditions(
        bundle: URL,
        isArchiveOperationRunning: () -> Bool
    ) throws {
        let path = bundle.standardizedFileURL.path
        if path.contains("/AppTranslocation/") {
            throw EngineUpdateError.appTranslocated(path)
        }
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resources.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw EngineUpdateError.bundleNotWritable("\(resources.path) is missing.")
        }
        guard FileManager.default.isWritableFile(atPath: resources.path) else {
            throw EngineUpdateError.bundleNotWritable(path)
        }
        let probe = resources.appendingPathComponent(".sevenzip-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            throw EngineUpdateError.bundleNotWritable(path)
        }
        if isArchiveOperationRunning() {
            throw EngineUpdateError.archiveOperationRunning
        }
    }

    // MARK: - Release metadata

    private func fetchRelease(tag: String?, etag: String?) async throws -> GitHubRelease {
        if let tag, EngineVersion(tag) == nil {
            throw EngineUpdateError.invalidRelease("“\(tag)” is not a valid 7-Zip release tag.")
        }
        let url = tag.map {
            URL(string: "https://api.github.com/repos/ip7z/7zip/releases/tags/\($0)")!
        } ?? Self.latestReleaseURL

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Finder7-update-check", forHTTPHeaderField: "User-Agent")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw EngineUpdateError.cancelled
        } catch {
            throw EngineUpdateError.offline(error.localizedDescription)
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw EngineUpdateError.invalidRelease("GitHub returned a non-HTTP response.")
        }
        let headers = http.allHeaderFields
        let body = String(decoding: data, as: UTF8.self)
        if let rateLimit = rateLimitError(status: http.statusCode, headers: headers, body: body) {
            throw rateLimit
        }
        switch http.statusCode {
        case 304:
            guard let cached = cache.cachedRelease else {
                throw EngineUpdateError.invalidRelease("GitHub returned 304 but no cached release exists.")
            }
            return cached
        case 200:
            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                guard release.version != nil else {
                    throw EngineUpdateError.invalidRelease("GitHub returned tag “\(release.tagName)”.")
                }
                cache.save(
                    release: release,
                    installedVersion: try installedManifest.engineVersion ?? "",
                    checkedAt: now(),
                    etag: http.value(forHTTPHeaderField: "ETag")
                )
                return release
            } catch let error as EngineUpdateError {
                throw error
            } catch {
                throw EngineUpdateError.invalidRelease(error.localizedDescription)
            }
        default:
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineUpdateError.httpStatus(
                http.statusCode,
                detail.isEmpty ? "No response body." : String(detail.prefix(500))
            )
        }
    }

    private func rateLimitError(status: Int, headers: [AnyHashable: Any], body: String) -> EngineUpdateError? {
        guard status == 403 || status == 429 else { return nil }
        let remaining = (headers["X-RateLimit-Remaining"] as? String)
            ?? (headers["x-ratelimit-remaining"] as? String)
        let reset = (headers["X-RateLimit-Reset"] as? String)
            ?? (headers["x-ratelimit-reset"] as? String)
        let retryAfter = (headers["Retry-After"] as? String)
            ?? (headers["retry-after"] as? String)

        var until: Date?
        if let reset, let epoch = TimeInterval(reset) {
            until = Date(timeIntervalSince1970: epoch)
        } else if let retryAfter, let seconds = TimeInterval(retryAfter) {
            until = now().addingTimeInterval(seconds)
        }
        if remaining == "0" || until != nil {
            if let until { cache.rateLimitedUntil = until }
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return EngineUpdateError.rateLimited(
                until: until,
                detail: detail.isEmpty ? "GitHub asked the updater to slow down." : String(detail.prefix(500))
            )
        }
        return nil
    }

    // MARK: - Local fixtures

    private func loadLocalRelease(directory: URL, requestedTag: String?) throws -> GitHubRelease {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw EngineUpdateError.invalidRelease("Fixture directory \(directory.path) does not exist.")
        }

        let releaseJSON = directory.appendingPathComponent("release.json")
        if fileManager.fileExists(atPath: releaseJSON.path) {
            var release = try JSONDecoder().decode(GitHubRelease.self, from: Data(contentsOf: releaseJSON))
            guard let version = release.version else {
                throw EngineUpdateError.invalidRelease("release.json has an invalid tag.")
            }
            if let requestedTag, requestedTag != version.raw {
                throw EngineUpdateError.invalidRelease("Fixture is \(version.raw), not \(requestedTag).")
            }
            release = try localize(release, in: directory)
            return release
        }

        var tags: Set<String> = []
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in contents {
            if let tag = EngineAssetMapping.tag(fromAssetName: file.lastPathComponent) {
                tags.insert(tag)
            }
        }
        guard let tag = requestedTag ?? tags.sorted(by: { (EngineVersion($0) ?? EngineVersion("0")!) < (EngineVersion($1) ?? EngineVersion("0")!) }).last,
              let version = EngineVersion(tag)
        else {
            throw EngineUpdateError.invalidRelease(
                "Fixture directory has no 7z<version>-mac.tar.xz asset and no release.json."
            )
        }
        guard tags.contains(tag) else {
            throw EngineUpdateError.invalidRelease("Fixture directory has no assets for \(tag).")
        }

        let sums = try loadSHA256Sums(in: directory)
        var assets: [GitHubRelease.Asset] = []
        for name in [version.assetNames.arm64, version.assetNames.x86_64] {
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let size = ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
            let digest: String?
            if let known = sums[name] {
                digest = "sha256:\(known)"
            } else {
                digest = "sha256:\(try FileHash.sha256(of: url))"
            }
            assets.append(GitHubRelease.Asset(
                name: name,
                browserDownloadURL: url,
                size: size,
                digest: digest,
                contentType: "application/octet-stream"
            ))
        }
        guard assets.contains(where: { $0.name == version.assetNames.arm64 }) else {
            throw EngineUpdateError.noMacOSAsset(tag: tag, missing: version.assetNames.arm64)
        }
        return GitHubRelease(
            tagName: tag,
            publishedAt: nil,
            htmlURL: version.releaseURL?.absoluteString,
            assets: assets
        )
    }

    private func localize(_ release: GitHubRelease, in directory: URL) throws -> GitHubRelease {
        let sums = try loadSHA256Sums(in: directory)
        let assets = release.assets.map { asset -> GitHubRelease.Asset in
            let local = directory.appendingPathComponent(asset.name)
            let size = ((try? FileManager.default.attributesOfItem(atPath: local.path))?[.size] as? NSNumber)?.int64Value
                ?? asset.size
            let digest = asset.sha256 ?? sums[asset.name] ?? (try? FileHash.sha256(of: local))
            return GitHubRelease.Asset(
                name: asset.name,
                browserDownloadURL: local,
                size: size,
                digest: digest.map { "sha256:\($0)" },
                contentType: asset.contentType
            )
        }
        return GitHubRelease(
            tagName: release.tagName,
            publishedAt: release.publishedAt,
            htmlURL: release.htmlURL,
            assets: assets
        )
    }

    private func loadSHA256Sums(in directory: URL) throws -> [String: String] {
        for name in ["SHA256SUMS", "sha256sums.txt", "SHA256SUMS.txt"] {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var sums: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2 else { continue }
                let hash = String(parts[0]).lowercased()
                guard hash.count == 64 else { continue }
                var file = String(parts[1])
                if file.hasPrefix("*") { file.removeFirst() }
                sums[file] = hash
            }
            if !sums.isEmpty { return sums }
        }
        return [:]
    }

    // MARK: - Download and verification

    private func obtain(
        _ asset: GitHubRelease.Asset,
        to destination: URL,
        requireDigest: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if asset.browserDownloadURL.isFileURL {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: asset.browserDownloadURL, to: destination)
                progress(1)
            } catch {
                throw EngineUpdateError.downloadFailed(asset.name, error.localizedDescription)
            }
        } else {
            guard asset.browserDownloadURL.host == "github.com" else {
                throw EngineUpdateError.downloadFailed(
                    asset.name,
                    "Refusing a download from \(asset.browserDownloadURL.host ?? "an unknown host"); expected github.com."
                )
            }
            try await downloader.download(
                asset.browserDownloadURL,
                to: destination,
                expectedSize: asset.size,
                progress: progress
            )
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let expected = asset.size, size != expected {
            throw EngineUpdateError.sizeMismatch(asset.name, expected: expected, actual: size)
        }
        guard let expectedDigest = asset.sha256 else {
            if requireDigest {
                throw EngineUpdateError.missingDigest(asset.name)
            }
            return
        }
        let actual = try FileHash.sha256(of: destination)
        guard actual == expectedDigest else {
            throw EngineUpdateError.checksumMismatch(
                asset.name,
                expected: expectedDigest,
                actual: actual
            )
        }
    }

    private func extract(_ asset: GitHubRelease.Asset, from archive: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try CommandRunner.runChecked(
                ToolPaths.tar,
                arguments: ["-xJf", archive.path, "-C", directory.path],
                step: "extracting \(asset.name)"
            )
        } catch {
            throw EngineUpdateError.extractionFailed(asset.name, error.localizedDescription)
        }
        guard let binary = Self.find("7zz", in: directory) else {
            throw EngineUpdateError.missingArchiveMember(asset: asset.name, member: "7zz")
        }
        guard Self.find("License.txt", in: directory) != nil else {
            throw EngineUpdateError.missingArchiveMember(asset: asset.name, member: "License.txt")
        }
        return binary
    }

    private func architectures(of binary: URL) throws -> Set<String> {
        let result = try CommandRunner.runChecked(
            ToolPaths.lipo,
            arguments: ["-archs", binary.path],
            step: "checking the architecture of \(binary.lastPathComponent)"
        )
        return Set(result.stdout.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private func verifyBanner(of binary: URL, expected: EngineVersion) throws {
        let result = try CommandRunner.run(binary.path, arguments: [])
        let banner = result.combined
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        guard banner.contains(expected.raw) else {
            throw EngineUpdateError.bannerMismatch(expected: expected.raw, actual: banner)
        }
    }

    private func smokeTest(binary: URL) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("finder7-engine-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("hello.txt")
        let expected = Data("hello from the updated engine\n".utf8)
        try expected.write(to: source)
        let archive = root.appendingPathComponent("smoke.7z")
        let output = root.appendingPathComponent("out", isDirectory: true)

        do {
            try CommandRunner.runChecked(
                binary.path,
                arguments: ["a", archive.path, source.path, "-mx=1", "-y"],
                step: "smoke test: creating an archive"
            )
            try CommandRunner.runChecked(
                binary.path,
                arguments: ["t", archive.path],
                step: "smoke test: testing the archive"
            )
            try CommandRunner.runChecked(
                binary.path,
                arguments: ["x", archive.path, "-o\(output.path)", "-y"],
                step: "smoke test: extracting the archive"
            )
        } catch {
            throw EngineUpdateError.smokeTestFailed(error.localizedDescription)
        }
        let extracted = output.appendingPathComponent("hello.txt")
        guard (try? Data(contentsOf: extracted)) == expected else {
            throw EngineUpdateError.smokeTestFailed("Extracted content did not match the source file.")
        }
    }

    private static func find(_ name: String, in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}
