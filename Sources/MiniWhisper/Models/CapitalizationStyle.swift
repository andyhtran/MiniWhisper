import Foundation

/// Capitalization mode applied to cleaned transcription text.
///
/// Three-way enum rather than a pair of booleans so invalid combinations
/// (both "auto" and "casual" on at once) can't be expressed.
enum CapitalizationStyle: String, Sendable, CaseIterable {
    /// Uppercase the first character of the transcript. Sentence-style.
    case auto

    /// Lowercase every character. Acronyms and brand capitalization included.
    case casual

    /// Leave casing untouched — verbatim model output.
    case off

    /// Default for fresh installs — sentence-style capitalization on.
    static let defaultStyle: CapitalizationStyle = .auto

    /// Human-readable label for pickers.
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .off: return "Off"
        case .casual: return "Casual"
        }
    }
}
