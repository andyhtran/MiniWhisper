import Testing
@testable import MiniWhisper

/// `CustomProvider.normalizeEndpoint` is the entire forgiveness budget for
/// user-pasted endpoint URLs — once it returns, the transcribe upload trusts
/// the result and POSTs straight to it. Each row pins one input shape from
/// the user's mental model: bare host, partial path, full path, trailing
/// slash, casing quirks, and a couple of non-standard prefixes that must
/// stay verbatim.
struct CustomProviderURLTests {
    @Test(arguments: [
        // Bare host — adds scheme + the canonical OpenAI path.
        ("api.openai.com", "https://api.openai.com/v1/audio/transcriptions"),
        ("api.openai.com/", "https://api.openai.com/v1/audio/transcriptions"),

        // Partial path: `/v1` and `/v1/audio` must auto-complete to the
        // full transcriptions endpoint. These were the silent-404 cases
        // before normalization landed.
        ("api.openai.com/v1", "https://api.openai.com/v1/audio/transcriptions"),
        ("api.openai.com/v1/", "https://api.openai.com/v1/audio/transcriptions"),
        ("api.openai.com/v1/audio", "https://api.openai.com/v1/audio/transcriptions"),
        ("api.openai.com/v1/audio/", "https://api.openai.com/v1/audio/transcriptions"),

        // Full URL — pass through, just normalize trailing slash.
        ("api.openai.com/v1/audio/transcriptions",
         "https://api.openai.com/v1/audio/transcriptions"),
        ("api.openai.com/v1/audio/transcriptions/",
         "https://api.openai.com/v1/audio/transcriptions"),
        ("https://api.openai.com/v1/audio/transcriptions",
         "https://api.openai.com/v1/audio/transcriptions"),

        // Scheme already present — don't double-prepend.
        ("https://api.openai.com", "https://api.openai.com/v1/audio/transcriptions"),
        ("http://localhost:8080", "http://localhost:8080/v1/audio/transcriptions"),

        // Mixed-case scheme — `hasPrefix` is case-sensitive, so the lowercased
        // check is what stops us double-prepending.
        ("HTTPS://api.openai.com", "HTTPS://api.openai.com/v1/audio/transcriptions"),

        // Non-standard prefix (Azure / Cloudflare AI Gateway / self-hosted
        // proxy) — preserve verbatim. We don't know better than the user.
        ("https://gateway.example.com/openai/v1/audio/transcriptions",
         "https://gateway.example.com/openai/v1/audio/transcriptions"),
        ("https://my-proxy.dev/whisper",
         "https://my-proxy.dev/whisper"),

        // Whitespace from sloppy paste — trim before processing.
        ("  api.openai.com  ", "https://api.openai.com/v1/audio/transcriptions"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(CustomProvider.normalizeEndpoint(input) == expected)
    }

    @Test func emptyStringReturnsEmpty() {
        #expect(CustomProvider.normalizeEndpoint("") == "")
        #expect(CustomProvider.normalizeEndpoint("   ") == "")
    }

    /// Azure deployments tack on a required `?api-version=...` query.
    /// `URLComponents` separates query from path, so the path-suffix rules
    /// don't see it and the query survives the round-trip untouched.
    @Test func preservesQueryString() {
        let input = "https://my-resource.openai.azure.com/openai/deployments/whisper/audio/transcriptions?api-version=2024-02-01"
        #expect(CustomProvider.normalizeEndpoint(input) == input)
    }
}
