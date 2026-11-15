/// The built-in web searches: general search engines, an encyclopedia, maps, video, code hosting,
/// package registries and developer documentation. Each takes the typed text as its first argument,
/// so each can be a fallback.
///
/// Keywords are whole words or abbreviations of three letters or more, so a short query such as
/// "a" or "so" still finds apps first. People add their own short keywords or aliases.
///
/// IDs are stable: they key the user's learning, aliases and hotkeys, and restoring the defaults
/// finds each search by its ID. Never change one. Add new searches at the end; they join an existing
/// user's list the next time the file loads, unless the user deleted one with the same ID.
nonisolated enum DefaultSearches {
    /// The default search engine until the user picks another.
    static let defaultEngineID = "google"

    /// Every built-in search, in the order the list shows them.
    static let all: [Quicklink] = [
        // General search engines.
        // Google is the default engine, which is always a fallback, so it needs no mark of its own.
        search("google", "Google", "https://www.google.com/search?q=", ["google"]),
        search("duckduckgo", "DuckDuckGo", "https://duckduckgo.com/?q=", ["ddg", "duckduckgo"]),
        search("bing", "Bing", "https://www.bing.com/search?q=", ["bing"]),
        search("brave", "Brave Search", "https://search.brave.com/search?q=", ["brave"]),
        search("kagi", "Kagi", "https://kagi.com/search?q=", ["kagi"]),
        // Reference.
        search(
            "wikipedia", "Wikipedia", "https://en.wikipedia.org/wiki/Special:Search?search=",
            ["wiki", "wikipedia"], fallback: true),
        search(
            "wiktionary", "Wiktionary", "https://en.wiktionary.org/wiki/Special:Search?search=",
            ["define", "dictionary", "wiktionary"]),
        search("wolframalpha", "Wolfram Alpha", "https://www.wolframalpha.com/input?i=", ["wolfram", "wolframalpha"]),
        // Maps.
        search("applemaps", "Apple Maps", "https://maps.apple.com/?q=", ["maps", "applemaps"]),
        search(
            "googlemaps", "Google Maps", "https://www.google.com/maps/search/?api=1&query=", ["gmaps", "googlemaps"]),
        // Video, film and shopping.
        search("youtube", "YouTube", "https://www.youtube.com/results?search_query=", ["youtube", "video"]),
        search("imdb", "IMDb", "https://www.imdb.com/find/?q=", ["imdb", "movies"]),
        search("amazon", "Amazon", "https://www.amazon.com/s?k=", ["amazon", "shopping"]),
        // Community.
        search("reddit", "Reddit", "https://www.reddit.com/search/?q=", ["reddit"]),
        search("x", "X", "https://x.com/search?q=", ["twitter", "tweets"]),
        search("hackernews", "Hacker News", "https://hn.algolia.com/?q=", ["hackernews"]),
        // More from Google. Translate shows a second, optional argument for the target language.
        search("googleimages", "Google Images", "https://www.google.com/search?tbm=isch&q=", ["images", "img"]),
        Quicklink(
            id: "googletranslate", name: Strings.searchSite("Google Translate"),
            link: "https://translate.google.com/?sl=auto&text=" + query
                + "&tl={argument name=\"To\" default=\"en\"}&op=translate",
            keywords: ["translate"], isBuiltIn: true),
        // Code hosting and questions.
        search("github", "GitHub", "https://github.com/search?q=", ["github"]),
        search("gitlab", "GitLab", "https://gitlab.com/search?search=", ["gitlab"]),
        search("stackoverflow", "Stack Overflow", "https://stackoverflow.com/search?q=", ["stackoverflow"]),
        // Developer documentation.
        search("mdn", "MDN Web Docs", "https://developer.mozilla.org/en-US/search?q=", ["mdn"]),
        search(
            "appledocs", "Apple Developer Documentation", "https://developer.apple.com/search/?q=",
            ["appledocs", "devdocs"]),
        search(
            "pythondocs", "Python Documentation", "https://docs.python.org/3/search.html?q=", ["pydocs", "pythondocs"]),
        search("docsrs", "Docs.rs", "https://docs.rs/releases/search?query=", ["docsrs", "rustdocs"]),
        // Package registries.
        search("npm", "npm", "https://www.npmjs.com/search?q=", ["npm"]),
        search("pypi", "PyPI", "https://pypi.org/search/?q=", ["pypi", "pip"]),
        search("crates", "crates.io", "https://crates.io/search?q=", ["crates", "cargo"]),
        search(
            "swiftpackageindex", "Swift Package Index", "https://swiftpackageindex.com/search?query=",
            ["swiftpm", "swiftpackages"]),
        search("gopackages", "Go Packages", "https://pkg.go.dev/search?q=", ["gopkg", "godoc"]),
    ]

    /// The built-in search with this ID.
    static func quicklink(id: String) -> Quicklink? {
        all.first { $0.id == id }
    }

    /// The argument every built-in search puts the typed text in.
    private static let query = "{argument name=\"\(LinkTemplate.queryArgumentName)\"}"

    private static func search(
        _ id: String, _ site: String, _ prefix: String, _ keywords: [String], fallback: Bool = false
    ) -> Quicklink {
        Quicklink(
            id: id, name: Strings.searchSite(site), link: prefix + query, keywords: keywords, isFallback: fallback,
            isBuiltIn: true)
    }
}
