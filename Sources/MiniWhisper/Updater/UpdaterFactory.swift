import Foundation
import Security

#if canImport(Sparkle) && ENABLE_SPARKLE
@MainActor
func makeUpdaterController() -> UpdaterProviding {
    let bundleURL = Bundle.main.bundleURL

    guard bundleURL.pathExtension == "app" else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    guard isDeveloperIDSigned(bundleURL: bundleURL) else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    let defaults = UserDefaults.standard
    let autoUpdateKey = "autoUpdateEnabled"
    let savedAutoUpdate = (defaults.object(forKey: autoUpdateKey) as? Bool) ?? true
    return SparkleUpdaterController(savedAutoUpdate: savedAutoUpdate)
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
    DisabledUpdaterController()
}
#endif
