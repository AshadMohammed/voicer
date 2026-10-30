import Foundation

/// A call app or browser that can be behind a process using the microphone.
struct CallSource: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case app, browser }
    let id: String      // stable key: the main app's bundle ID, e.g. "us.zoom.xos"
    let name: String    // what the prompt says: "Zoom", "Microsoft Teams", "Arc"
    let kind: Kind
}

/// Catalogue of known call apps and browsers, and of meeting-site URLs.
enum CallAppCatalog {

    // MARK: - Source lookup

    /// The call app or browser behind a mic-using process, or `nil` for anything else.
    /// Matches by bundle-ID prefix, case-insensitively, so helper processes count:
    /// `"company.thebrowser.browser.helper"` → Arc, `"com.tinyspeck.slackmacgap.helper"` → Slack.
    static func source(forBundleID bundleID: String) -> CallSource? {
        let lower = bundleID.lowercased()
        for entry in catalog {
            for prefix in entry.prefixes {
                if matchesPrefix(lower, prefix: prefix) {
                    return entry.source
                }
            }
        }
        return nil
    }

    /// The meeting site a tab URL belongs to (`"Google Meet"`, `"Microsoft Teams"`, `"Zoom"`,
    /// `"Whereby"`), or `nil`.
    static func meetingSite(forURL url: String) -> String? {
        guard let host = host(from: url) else { return nil }
        let lower = host.lowercased()

        if lower == "meet.google.com" { return "Google Meet" }
        if lower == "teams.microsoft.com" || lower == "teams.live.com" || lower == "teams.cloud.microsoft" {
            return "Microsoft Teams"
        }
        if lower == "zoom.us" || lower.hasSuffix(".zoom.us") { return "Zoom" }
        if lower == "whereby.com" || lower.hasSuffix(".whereby.com") { return "Whereby" }
        return nil
    }

    // MARK: - Private

    private struct Entry {
        let source: CallSource
        let prefixes: [String]   // lowercased
    }

    /// Ordered so that more-specific prefixes are checked first where two overlap
    /// (e.g. `com.microsoft.teams2` before `com.microsoft.teams`).
    private static let catalog: [Entry] = [
        // Apps
        Entry(source: CallSource(id: "us.zoom.xos", name: "Zoom", kind: .app),
              prefixes: ["us.zoom.xos"]),
        Entry(source: CallSource(id: "com.microsoft.teams2", name: "Microsoft Teams", kind: .app),
              prefixes: ["com.microsoft.teams2", "com.microsoft.teams"]),
        Entry(source: CallSource(id: "com.apple.FaceTime", name: "FaceTime", kind: .app),
              prefixes: ["com.apple.facetime", "com.apple.avconferenced"]),
        Entry(source: CallSource(id: "com.tinyspeck.slackmacgap", name: "Slack", kind: .app),
              prefixes: ["com.tinyspeck.slackmacgap"]),
        Entry(source: CallSource(id: "Cisco-Systems.Spark", name: "Webex", kind: .app),
              prefixes: ["cisco-systems.spark", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager"]),
        Entry(source: CallSource(id: "com.hnc.Discord", name: "Discord", kind: .app),
              prefixes: ["com.hnc.discord"]),
        Entry(source: CallSource(id: "net.whatsapp.WhatsApp", name: "WhatsApp", kind: .app),
              prefixes: ["net.whatsapp.whatsapp"]),
        // Browsers
        Entry(source: CallSource(id: "company.thebrowser.Browser", name: "Arc", kind: .browser),
              prefixes: ["company.thebrowser.browser"]),
        Entry(source: CallSource(id: "company.thebrowser.dia", name: "Dia", kind: .browser),
              prefixes: ["company.thebrowser.dia"]),
        Entry(source: CallSource(id: "com.google.Chrome", name: "Google Chrome", kind: .browser),
              prefixes: ["com.google.chrome"]),
        Entry(source: CallSource(id: "com.apple.Safari", name: "Safari", kind: .browser),
              prefixes: ["com.apple.safari", "com.apple.webkit.gpu"]),
        Entry(source: CallSource(id: "app.zen-browser.zen", name: "Zen", kind: .browser),
              prefixes: ["app.zen-browser.zen"]),
        Entry(source: CallSource(id: "org.mozilla.firefox", name: "Firefox", kind: .browser),
              prefixes: ["org.mozilla.firefox"]),
    ]

    /// A prefix matches only on a whole dot-separated component boundary.
    private static func matchesPrefix(_ bundleID: String, prefix: String) -> Bool {
        if bundleID == prefix { return true }
        if bundleID.hasPrefix(prefix + ".") { return true }
        return false
    }

    /// Extracts the host from a URL string. Prepends `https://` if `URL(string:)` gives no host.
    private static func host(from raw: String) -> String? {
        if let url = URL(string: raw), let h = url.host, !h.isEmpty { return h }
        // Accept a bare URL without a scheme.
        if let url = URL(string: "https://" + raw), let h = url.host, !h.isEmpty { return h }
        return nil
    }
}
