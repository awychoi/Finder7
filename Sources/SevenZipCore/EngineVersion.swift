import Foundation

/// A 7-Zip release version such as `26.06`.
///
/// 7-Zip tags are numeric and dot-separated. Comparisons are numeric per
/// component (`26.10 > 26.9`, `26.06 == 26.6`) while the original spelling is
/// preserved because it is also the GitHub tag.
public struct EngineVersion: Hashable, Comparable, CustomStringConvertible, Sendable {
    /// The version exactly as it appears in the release tag, without a leading `v`.
    public let raw: String
    /// Numeric components without leading-zero normalization, for display.
    public let components: [Int]

    public init?(_ text: String) {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("v") || candidate.hasPrefix("V") {
            candidate.removeFirst()
        }
        guard !candidate.isEmpty,
              candidate.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil
        else { return nil }

        var parsed: [Int] = []
        for part in candidate.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part) else { return nil }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        self.raw = candidate
        self.components = parsed
    }

    public var description: String { raw }

    /// Digits-only form used in 7-Zip asset names (`26.06` becomes `2606`).
    public var assetCode: String {
        raw.replacingOccurrences(of: ".", with: "")
    }

    /// The official macOS asset names for this release.
    ///
    /// 7-Zip 26.06 ships separate arm64 and x86_64 archives. Older releases
    /// such as 26.05 shipped a single universal archive for the arm64 name, so
    /// the x86_64 asset is optional until the archive is inspected.
    public var assetNames: EngineAssetNames {
        let base = "7z\(assetCode)-mac"
        return EngineAssetNames(
            arm64: "\(base).tar.xz",
            x86_64: "\(base)-x64.tar.xz"
        )
    }

    public var releaseURL: URL? {
        URL(string: "https://github.com/ip7z/7zip/releases/tag/\(raw)")
    }

    public func isNewer(than other: EngineVersion) -> Bool {
        self > other
    }

    /// Equality is numeric: `26.06 == 26.6` and `27 == 27.0`.
    public static func == (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        lhs.normalizedComponents == rhs.normalizedComponents
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedComponents)
    }

    private var normalizedComponents: [Int] {
        var values = components
        while values.count > 1, values.last == 0 {
            values.removeLast()
        }
        return values
    }

    public static func < (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// Returns `true` when `candidate` is a valid version newer than `installed`.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let new = EngineVersion(candidate), let old = EngineVersion(installed) else {
            return false
        }
        return new > old
    }
}

public struct EngineAssetNames: Hashable, Sendable {
    public let arm64: String
    public let x86_64: String
}

public enum EngineAssetArchitecture: String, CaseIterable, Sendable {
    case arm64
    case x86_64

    public var assetSuffix: String {
        switch self {
        case .arm64: return "mac"
        case .x86_64: return "mac-x64"
        }
    }

    public var lipoName: String { rawValue }
}

/// Maps a release tag onto the official GitHub download asset names.
public enum EngineAssetMapping {
    public static func assetCode(for tag: String) -> String? {
        EngineVersion(tag)?.assetCode
    }

    public static func assetNames(for tag: String) -> EngineAssetNames? {
        EngineVersion(tag)?.assetNames
    }

    public static func assetURL(tag: String, name: String) -> URL? {
        guard let version = EngineVersion(tag), isValidAssetName(name, for: version) else {
            return nil
        }
        return URL(string: "https://github.com/ip7z/7zip/releases/download/\(version.raw)/\(name)")
    }

    public static func isValidAssetName(_ name: String, for version: EngineVersion) -> Bool {
        name == version.assetNames.arm64 || name == version.assetNames.x86_64
    }

    /// Extracts a tag from an official macOS asset file name, used by the
    /// offline fixture path where no release metadata is available.
    public static func tag(fromAssetName name: String) -> String? {
        let pattern = #"^7z([0-9]{2})([0-9]{2})-mac(?:-x64)?\.tar\.xz$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
              let majorRange = Range(match.range(at: 1), in: name),
              let minorRange = Range(match.range(at: 2), in: name)
        else { return nil }
        return "\(name[majorRange]).\(name[minorRange])"
    }
}
