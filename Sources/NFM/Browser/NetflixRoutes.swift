import Foundation

/// Everything the app knows about Netflix URLs.
enum NetflixRoutes {
    static let base = URL(string: "https://www.netflix.com")!

    static let home = url("/browse")
    static let tvShows = url("/browse/genre/83")
    static let movies = url("/browse/genre/34399")
    static let newAndPopular = url("/latest")
    static let myList = url("/browse/my-list")
    static let languages = url("/browse/original-audio")
    static let account = url("/account")
    static let help = URL(string: "https://help.netflix.com")!

    static func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }

    static func search(_ query: String) -> URL {
        var components = URLComponents(url: url("/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    /// Hosts whose pages stay inside the app. Everything else opens in the
    /// user's default browser when they click a link to it.
    static func isNetflixHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let roots = ["netflix.com", "netflix.net", "nflxext.com", "nflximg.net", "nflxso.net", "nflxvideo.net"]
        return roots.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isWatchURL(_ url: URL?) -> Bool {
        url?.path.hasPrefix("/watch") ?? false
    }

    /// The page to open on launch: the last page visited, but never straight
    /// into playback (a `/watch/ID` page becomes that title's detail page).
    static func startURL() -> URL {
        guard Prefs.restoreLastPage, let last = Prefs.lastURL, isNetflixHost(last.host) else { return home }
        if let id = watchID(last) { return url("/title/\(id)") }
        let path = last.path
        if path.hasPrefix("/login") || path.hasPrefix("/logout") || path.hasPrefix("/signup") { return home }
        return last
    }

    static func watchID(_ url: URL) -> String? {
        let parts = url.pathComponents
        guard parts.count >= 3, parts[1] == "watch" else { return nil }
        return parts[2]
    }

    /// Turns whatever the user typed or opened into a Netflix URL:
    /// `https://www.netflix.com/title/81234567`, `netflix.com/watch/…`,
    /// `nflx.it/…` short links, `netflix://title/81234567`, `nfm://search?q=…`,
    /// or a bare title ID. Returns `nil` when it is not a link (i.e. a search).
    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.allSatisfy(\.isNumber), text.count >= 6 {
            return url("/title/\(text)")
        }

        if let custom = URL(string: text), let scheme = custom.scheme?.lowercased(),
           scheme == "netflix" || scheme == "nfm" {
            return resolveCustomScheme(custom)
        }

        var candidate = text
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let parsed = URL(string: candidate), let host = parsed.host, host.contains(".") else { return nil }
        if host.lowercased() == "nflx.it" || isNetflixHost(host) {
            var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url
        }
        return nil
    }

    /// `netflix://title/123`, `netflix://watch/123`, `nfm://search?q=dark`,
    /// `nfm://browse/my-list` → https://www.netflix.com/…
    static func resolveCustomScheme(_ link: URL) -> URL {
        let components = URLComponents(url: link, resolvingAgainstBaseURL: false)
        let host = link.host ?? ""
        var path = "/" + ([host] + link.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }.joined(separator: "/")
        if path == "/" { path = "/browse" }
        if host == "search", let q = components?.queryItems?.first(where: { $0.name == "q" })?.value {
            return search(q)
        }
        var out = URLComponents(url: url(path), resolvingAgainstBaseURL: false)!
        out.queryItems = components?.queryItems
        return out.url ?? home
    }
}
