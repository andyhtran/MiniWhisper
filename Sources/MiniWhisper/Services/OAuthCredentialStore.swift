import Foundation
import Security

/// Reads OAuth credentials that the user's installed Claude Code / Codex
/// CLIs maintain. We never write back — the CLIs own the refresh state
/// machine. If our read returns an expired access token, the caller
/// triggers a refresh by spawning the CLI (see `OAuthRefreshTrigger`)
/// and re-reads from the same source.
///
/// Anthropic: macOS Keychain item `Claude Code-credentials`. Reading it
/// from MiniWhisper's process triggers a one-time keychain access prompt
/// — user grants "Always Allow" once.
///
/// OpenAI Codex: `~/.codex/auth.json`, mode 0600, no keychain.
enum OAuthCredentialStore {
    struct AnthropicCredentials: Sendable {
        let accessToken: String
    }

    struct CodexCredentials: Sendable {
        let accessToken: String
        let accountId: String
    }

    enum Error: LocalizedError {
        case keychainItemNotFound
        case keychainAccessDenied(OSStatus)
        case keychainOtherStatus(OSStatus)
        case codexAuthFileMissing(String)
        case malformedPayload(String)

        var errorDescription: String? {
            switch self {
            case .keychainItemNotFound:
                return "Claude Code keychain entry not found. Run `claude` once to log in."
            case .keychainAccessDenied(let status):
                return "Keychain access denied (status \(status)). Approve the prompt or run `claude` once."
            case .keychainOtherStatus(let status):
                return "Keychain read failed (status \(status))."
            case .codexAuthFileMissing(let path):
                return "Codex auth file not found at \(path). Run `codex login` first."
            case .malformedPayload(let detail):
                return "Auth payload malformed: \(detail)."
            }
        }
    }

    static func anthropic() throws -> AnthropicCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw Error.keychainItemNotFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw Error.keychainAccessDenied(status)
        default:
            throw Error.keychainOtherStatus(status)
        }
        guard let data = result as? Data else {
            throw Error.malformedPayload("keychain returned no data")
        }
        let payload: KeychainPayload
        do {
            payload = try JSONDecoder().decode(KeychainPayload.self, from: data)
        } catch {
            throw Error.malformedPayload("keychain JSON decode failed: \(error.localizedDescription)")
        }
        return AnthropicCredentials(accessToken: payload.claudeAiOauth.accessToken)
    }

    static func openAICodex() throws -> CodexCredentials {
        let path = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw Error.codexAuthFileMissing(path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw Error.malformedPayload("codex auth.json read failed: \(error.localizedDescription)")
        }
        let payload: CodexFilePayload
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            payload = try decoder.decode(CodexFilePayload.self, from: data)
        } catch {
            throw Error.malformedPayload("codex auth.json decode failed: \(error.localizedDescription)")
        }
        return CodexCredentials(
            accessToken: payload.tokens.accessToken,
            accountId: payload.tokens.accountId
        )
    }

    private struct KeychainPayload: Decodable {
        let claudeAiOauth: OAuth

        struct OAuth: Decodable {
            let accessToken: String
        }
    }

    private struct CodexFilePayload: Decodable {
        let tokens: Tokens

        struct Tokens: Decodable {
            let accessToken: String
            let accountId: String
        }
    }
}
