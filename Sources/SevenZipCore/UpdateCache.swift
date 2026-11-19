import Foundation

/// Persists the last release response for the 15-minute check cache and the
/// rate-limit backoff. The cache is deliberately tiny: one release JSON blob.
public final class UpdateCache: @unchecked Sendable {
    private struct State: Codable {
        var release: GitHubRelease
        var checkedAt: Date
        var installedVersion: String
        var etag: String?
    }

    private let defaults: UserDefaults
    private let prefix: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, prefix: String = "SevenZip.EngineUpdate.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public var lastCheckDate: Date? {
        get { defaults.object(forKey: prefix + "lastCheck") as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: prefix + "lastCheck") }
            else { defaults.removeObject(forKey: prefix + "lastCheck") }
        }
    }

    public var rateLimitedUntil: Date? {
        get { defaults.object(forKey: prefix + "rateLimitedUntil") as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: prefix + "rateLimitedUntil") }
            else { defaults.removeObject(forKey: prefix + "rateLimitedUntil") }
        }
    }

    public var cachedRelease: GitHubRelease? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: prefix + "state") else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data))?.release
    }

    public var etag: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: prefix + "state") else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data))?.etag
    }

    public func cachedState(installedVersion: String, maxAge: TimeInterval, now: Date) -> UpdateCheck? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: prefix + "state") else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(State.self, from: data),
              state.installedVersion == installedVersion,
              now.timeIntervalSince(state.checkedAt) >= 0,
              now.timeIntervalSince(state.checkedAt) < maxAge
        else { return nil }
        return try? UpdateCheck.evaluate(
            installedVersion: installedVersion,
            release: state.release,
            now: state.checkedAt
        )
    }

    public func save(release: GitHubRelease, installedVersion: String, checkedAt: Date, etag: String?) {
        lock.lock()
        defer { lock.unlock() }
        let state = State(
            release: release,
            checkedAt: checkedAt,
            installedVersion: installedVersion,
            etag: etag
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: prefix + "state")
        }
        lastCheckDate = checkedAt
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: prefix + "state")
        defaults.removeObject(forKey: prefix + "rateLimitedUntil")
        // Keep lastCheckDate so Settings can still show when the last check ran.
    }
}
