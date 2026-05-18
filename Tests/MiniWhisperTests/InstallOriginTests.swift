import Foundation
import Testing
@testable import MiniWhisper

@Suite("Install origin detection")
struct InstallOriginTests {
    @Test func homebrewCaskroomDetected() {
        let url = URL(fileURLWithPath: "/opt/homebrew/Caskroom/myapp/1.0/MyApp.app")
        #expect(InstallOrigin.isHomebrewCask(appBundleURL: url))
    }

    @Test func homebrewCaskroomAlternatePathDetected() {
        let url = URL(fileURLWithPath: "/usr/local/Homebrew/Caskroom/myapp/1.0/MyApp.app")
        #expect(InstallOrigin.isHomebrewCask(appBundleURL: url))
    }

    @Test func applicationsPathNotDetected() {
        let url = URL(fileURLWithPath: "/Applications/MyApp.app")
        #expect(!InstallOrigin.isHomebrewCask(appBundleURL: url))
    }

    @Test func userApplicationsPathNotDetected() {
        let url = URL(fileURLWithPath: "/Users/someone/Applications/MyApp.app")
        #expect(!InstallOrigin.isHomebrewCask(appBundleURL: url))
    }
}
