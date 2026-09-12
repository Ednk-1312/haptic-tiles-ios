import Foundation

/// Read-only app identity info for the Settings screen — lets you confirm at
/// a glance which build is installed on a device (useful when sideloading).
enum AppInfo {
    /// e.g. "1.1 (2)" — marketing version + build number.
    static var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }
}