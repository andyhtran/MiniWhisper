import Foundation
import Testing
@testable import MiniWhisper

struct CustomProviderSecretsTests {
    @Test func transcriptionSettingsEncodingOmitsAPIKey() throws {
        let settings = CustomProviderSettings(
            endpointURL: "https://api.example.test/v1/audio/transcriptions",
            apiKey: "test-secret-value",
            modelName: "speech-model"
        )

        let data = try JSONEncoder().encode(settings)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("test-secret-value"))
        #expect(!json.contains("apiKey"))

        let decoded = try JSONDecoder().decode(CustomProviderSettings.self, from: data)
        #expect(decoded.endpointURL == settings.endpointURL)
        #expect(decoded.modelName == settings.modelName)
        #expect(decoded.apiKey == "")
    }

    @Test func editSettingsEncodingOmitsAPIKey() throws {
        let settings = CustomEditProviderSettings(
            endpointURL: "https://api.example.test/v1/chat/completions",
            apiKey: "test-secret-value",
            modelName: "edit-model"
        )

        let data = try JSONEncoder().encode(settings)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("test-secret-value"))
        #expect(!json.contains("apiKey"))

        let decoded = try JSONDecoder().decode(CustomEditProviderSettings.self, from: data)
        #expect(decoded.endpointURL == settings.endpointURL)
        #expect(decoded.modelName == settings.modelName)
        #expect(decoded.apiKey == "")
    }
}
