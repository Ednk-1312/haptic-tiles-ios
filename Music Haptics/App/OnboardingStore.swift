import Foundation

/// Small, versioned first-launch flag for the tester-facing onboarding flow.
/// Keeping this separate from gameplay settings lets future onboarding updates
/// be introduced without changing haptic, audio, or chart preferences.
enum OnboardingStore {
    private static let completedKey = "onboarding.alpha1.completed"
    private static let versionKey = "onboarding.alpha1.version"
    static let currentVersion = 1

    static var isComplete: Bool {
        UserDefaults.standard.integer(forKey: versionKey) == currentVersion
            && UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markComplete() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: completedKey)
        defaults.set(currentVersion, forKey: versionKey)
    }

    #if DEBUG
    static func reset() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: completedKey)
        defaults.removeObject(forKey: versionKey)
        defaults.synchronize()
    }
    #endif
}
