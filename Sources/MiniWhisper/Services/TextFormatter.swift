import Foundation
import NaturalLanguage

/// Splits continuous transcription text into paragraphs separated by double
/// newlines, so long dictations don't paste as a wall of text.
///
/// ## Chunking Strategy
///
/// Each chunk accumulates sentences until one of these triggers:
///
/// 1. **Word count target reached**: ~50 words → chunk closes. Keeps
///    paragraphs roughly equal in visual weight.
///
/// 2. **Significant-sentence limit**: >4 "significant" sentences (4+ words)
///    forces a trim even if the word target wasn't reached.
///
/// Short utterances like "Yes.", "OK.", "I see." don't count toward the
/// sentence limit — they stay with their surrounding context rather than
/// forming their own paragraph.
enum TextFormatter {
    private static let targetWordCount = 50
    private static let maxSentencesPerChunk = 4
    private static let minWordsForSignificantSentence = 4

    static func format(_ text: String) -> String {
        let detectedLanguage = NLLanguageRecognizer.dominantLanguage(for: text)
        let tokenizerLanguage = detectedLanguage ?? .english

        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        sentenceTokenizer.setLanguage(tokenizerLanguage)

        let wordTokenizer = NLTokenizer(unit: .word)
        wordTokenizer.setLanguage(tokenizerLanguage)

        var allSentences = [String]()
        sentenceTokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { sentenceRange, _ in
            let rawSentence = String(text[sentenceRange])
            allSentences.append(rawSentence.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        }

        guard !allSentences.isEmpty else {
            return ""
        }

        // Pre-compute word counts once so the chunking loop doesn't re-tokenize
        // sentences it already looked at.
        let wordCounts = allSentences.map { countWords(in: $0, using: wordTokenizer) }

        var chunks = [String]()
        var processedIndex = 0

        while processedIndex < allSentences.count {
            var tentativeSentences = [(sentence: String, wordCount: Int)]()
            var chunkWordCount = 0
            var significantSentenceCount = 0

            for i in processedIndex ..< allSentences.count {
                let sentence = allSentences[i]
                let wordCount = wordCounts[i]

                tentativeSentences.append((sentence, wordCount))
                chunkWordCount += wordCount

                if wordCount >= minWordsForSignificantSentence {
                    significantSentenceCount += 1
                }

                if chunkWordCount >= targetWordCount {
                    break
                }
            }

            let finalSentences: [String] = if significantSentenceCount > maxSentencesPerChunk {
                trimToMaxSignificantSentences(tentativeSentences)
            } else {
                tentativeSentences.map(\.sentence)
            }

            if !finalSentences.isEmpty {
                chunks.append(finalSentences.joined(separator: " "))
                processedIndex += finalSentences.count
            } else {
                // Defensive: if we somehow can't form a chunk, advance to
                // avoid infinite looping on pathological input.
                processedIndex += max(tentativeSentences.count, 1)
            }
        }

        return chunks.joined(separator: "\n\n")
    }

    private static func countWords(in text: String, using tokenizer: NLTokenizer) -> Int {
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    /// Trims to at most `maxSentencesPerChunk` significant sentences.
    /// Short sentences (below `minWordsForSignificantSentence`) are included
    /// but don't tick the counter, so fragments like "Yes." stay with their
    /// context instead of orphaning into their own paragraph.
    private static func trimToMaxSignificantSentences(_ sentences: [(sentence: String, wordCount: Int)]) -> [String] {
        var result = [String]()
        var significantCount = 0

        for (sentence, wordCount) in sentences {
            result.append(sentence)
            if wordCount >= minWordsForSignificantSentence {
                significantCount += 1
                if significantCount >= maxSentencesPerChunk {
                    break
                }
            }
        }
        return result
    }
}
