import Foundation

/// User preferences for post-transcription text formatting. All knobs are
/// UserDefaults-backed because they're simple scalars that don't warrant
/// the file-based persistence used by replacements.
///
/// Defaults are conservative: sentence-case capitalization on as a safety net
/// for models that occasionally emit lowercase starts, but paragraph-splitting
/// and trailing-punctuation stripping are off so the first-run output closely
/// matches raw model output. Users opt in to the more aggressive transforms.
enum FormattingSettings {
    private enum Keys {
        static let capitalization = "FormattingCapitalizationStyle"
        static let autoParagraph = "FormattingAutoParagraph"
        static let dropTrailingPunctuation = "FormattingDropTrailingPunctuation"
        static let appendTrailingSpace = "FormattingAppendTrailingSpace"
        // Migration marker: the first read on a pristine install writes the
        // defaults so subsequent `bool(forKey:)` calls return the real value
        // rather than `false` (UserDefaults' zero-value for a missing bool).
        static let defaultsSeeded = "FormattingDefaultsSeeded"
    }

    static var capitalization: CapitalizationStyle {
        get {
            seedDefaultsIfNeeded()
            let raw = UserDefaults.standard.string(forKey: Keys.capitalization)
            return CapitalizationStyle(rawValue: raw ?? "") ?? .defaultStyle
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.capitalization)
        }
    }

    static var autoParagraph: Bool {
        get {
            seedDefaultsIfNeeded()
            return UserDefaults.standard.bool(forKey: Keys.autoParagraph)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoParagraph) }
    }

    static var dropTrailingPunctuation: Bool {
        get {
            seedDefaultsIfNeeded()
            return UserDefaults.standard.bool(forKey: Keys.dropTrailingPunctuation)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.dropTrailingPunctuation) }
    }

    /// Appends a single space to the transcription before paste so the
    /// user can immediately keep typing. Defaults to on for both fresh
    /// installs and existing ones predating this knob (the latter already
    /// have `defaultsSeeded` set, so the presence check is what reaches
    /// them rather than `seedDefaultsIfNeeded`).
    static var appendTrailingSpace: Bool {
        get { UserDefaults.standard.defaultsToTrue(forKey: Keys.appendTrailingSpace) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.appendTrailingSpace) }
    }

    /// Writes opt-in defaults once so `bool(forKey:)` returns real values
    /// instead of `false` on a fresh install. Must be called before every
    /// read — cheap (one UserDefaults bool check) and idempotent.
    private static func seedDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.defaultsSeeded) else { return }
        defaults.set(CapitalizationStyle.defaultStyle.rawValue, forKey: Keys.capitalization)
        defaults.set(false, forKey: Keys.autoParagraph)
        defaults.set(false, forKey: Keys.dropTrailingPunctuation)
        defaults.set(true, forKey: Keys.defaultsSeeded)
    }
}
