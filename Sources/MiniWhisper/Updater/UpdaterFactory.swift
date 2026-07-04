import Foundation
import Security

#if canImport(Sparkle) && ENABLE_SPARKLE
@MainActor
func makeUpdaterController() -> UpdaterProviding {
    #if DEBUG
    if let simulator = UpdateSimulator.configured() {
        return simulator
    }
    #endif

    let bundleURL = Bundle.main.bundleURL

    guard bundleURL.pathExtension == "app" else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    guard isDeveloperIDSigned(bundleURL: bundleURL) else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    guard hasUpdateFeed(bundle: .main) else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    let savedAutoUpdate = UpdaterDefaults.savedAutoUpdateEnabled()
    return SparkleUpdaterController(savedAutoUpdate: savedAutoUpdate)
}

private func hasUpdateFeed(bundle: Bundle) -> Bool {
    guard let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
        return false
    }
    return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode else { return false }

    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first else { return false }

    if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
        return summary.hasPrefix("Developer ID Application:")
    }
    return false
}
#else
@MainActor
func makeUpdaterController() -> UpdaterProviding {
    #if DEBUG
    if let simulator = UpdateSimulator.configured() {
        return simulator
    }
    #endif

    return DisabledUpdaterController()
}
#endif
