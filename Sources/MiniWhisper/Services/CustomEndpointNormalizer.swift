import Foundation

/// Forgiving URL normalization shared by the custom transcription and
/// custom edit endpoints. Users can paste any common prefix — bare host,
/// `/v1`, or `/v1/<subpath>` — and land on the correct canonical path.
/// Any other explicit path is preserved verbatim so non-standard hosts
/// (Cloudflare AI Gateway, Azure deployment URLs, self-hosted proxies
/// like `/openai/v1`) keep working.
///
/// Applied at request time rather than at save time so the user always
/// sees what they typed in the settings field.
enum CustomEndpointNormalizer {
    static func normalize(_ input: String, canonicalPath: String) -> String {
        var value = input.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }

        let lowered = value.lowercased()
        if !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") {
            value = "https://" + value
        }

        if value.hasSuffix("/") {
            value = String(value.dropLast())
        }

        guard var components = URLComponents(string: value), components.host != nil else {
            return value
        }

        let path = components.path
        if path.isEmpty || path == "/" {
            components.path = canonicalPath
        } else {
            // Walk canonical-path prefixes longest-first so a partial
            // `/v1/audio` wins over `/v1` and `/openai/v1` still matches
            // the bare `/v1` rule.
            let parts = canonicalPath.split(separator: "/").map(String.init)
            for i in (1..<parts.count).reversed() {
                let prefix = "/" + parts.prefix(i).joined(separator: "/")
                if path.hasSuffix(prefix) {
                    let remaining = "/" + parts.dropFirst(i).joined(separator: "/")
                    components.path = path + remaining
                    break
                }
            }
        }

        return components.string ?? value
    }
}
