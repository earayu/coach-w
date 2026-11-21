import Foundation

/// The token API base URL as typed or pasted in settings.
public enum ServerAddress {
    /// Trims whitespace and newlines; accepts only `http` / `https` URLs with a host.
    public static func parse(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}

extension String {
    /// Settings values are pasted from chats and notes: never keep the surrounding whitespace.
    public var trimmedForSettings: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
