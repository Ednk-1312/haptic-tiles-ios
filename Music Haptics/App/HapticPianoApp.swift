import SwiftData
import SwiftUI

@main
struct HapticPianoApp: App {
    private let container = PersistenceController.shared.container
    @StateObject private var settings: SettingsStore
    @StateObject private var mediaLibrary: MediaLibraryService
    @State private var appState: AppState
    /// Simulator launch flows such as `-demoAutoplay` present their own
    /// gameplay cover. Do not present onboarding simultaneously, which causes
    /// SwiftUI to queue a second full-screen presentation and emit an invalid
    /// configuration warning before gameplay starts.
    @State private var showOnboarding = !OnboardingStore.isComplete && !Self.isAutomationLaunch

    private static var isAutomationLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demoAutoplay")
            || arguments.contains("-demoPassive")
            || arguments.contains("-demoPreview")
            || arguments.contains("-demoCalibration")
            || arguments.contains("-demoReplay")
            || arguments.contains("-demoFile")
    }

    init() {
        let store = SettingsStore()
        let library = MediaLibraryService()
        _settings = StateObject(wrappedValue: store)
        _mediaLibrary = StateObject(wrappedValue: library)
        _appState = State(initialValue: AppState(container: PersistenceController.shared.container,
                                                 settings: store,
                                                 mediaLibrary: library,
                                                 ai: AISystem()))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(appState)
                .environmentObject(settings)
                .environmentObject(mediaLibrary)
                .modelContainer(container)
                .preferredColorScheme(settings.colorScheme)
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView()
                }
        }
    }
}