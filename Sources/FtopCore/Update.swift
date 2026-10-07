import Foundation

/// What ftop does about new releases.
public enum UpdateMode: String, Sendable, Codable, CaseIterable {
    /// Check once a day and install what is found.
    case install
    /// Check once a day and offer the update in the menu.
    case check
    /// Never contact the release server.
    case off
}

/// A dotted release number such as `0.1.2`; a leading `v` is accepted.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Without trailing zeros, so `0.1` equals `0.1.0`.
    public let parts: [Int]

    public init?(_ text: String) {
        let digits = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let fields = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.count <= 4 else { return nil }
        var parts: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.count <= 6, field.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(field) else { return nil }
            parts.append(number)
        }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        self.parts = parts
    }

    public var description: String {
        (parts + [Int](repeating: 0, count: max(0, 3 - parts.count))).map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// The newest published release, as far as an update needs it.
public struct ReleaseInfo: Sendable, Equatable {
    public var version: AppVersion
    public var archive: URL
    /// Lowercase hex SHA-256 of the archive, when the server states one.
    public var sha256: String?
}

public enum UpdateFeed {
    public static let latest = URL(string: "https://api.github.com/repos/Nongfsq/ftop/releases/latest")!
    /// Archives are taken from the project's own release downloads and nowhere else.
    static let downloadPrefix = "https://github.com/Nongfsq/ftop/releases/download/"

    public static func archiveName(_ version: AppVersion) -> String { "Ftop-\(version)-arm64.zip" }

    /// Reads GitHub's "latest release" answer. Nil when it is not a finished release
    /// with the expected archive at the expected address.
    public static func release(from data: Data) -> ReleaseInfo? {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
            var digest: String?
        }
        struct Release: Decodable {
            var tag_name: String
            var draft: Bool?
            var prerelease: Bool?
            var assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data), release.draft != true, release.prerelease != true,
            let version = AppVersion(release.tag_name),
            let asset = release.assets.first(where: { $0.name == archiveName(version) }),
            asset.browser_download_url.hasPrefix(downloadPrefix), let archive = URL(string: asset.browser_download_url)
        else { return nil }
        var sha256: String?
        if let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:") {
            let hex = String(digest.dropFirst(7))
            // A digest that is stated but malformed is not the same as none.
            guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
            sha256 = hex
        }
        return ReleaseInfo(version: version, archive: archive, sha256: sha256)
    }
}
