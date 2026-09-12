import SwiftData
import SwiftUI

@main
struct HapticPianoApp: App {
    private let container = PersistenceController.shared.container
    @StateObject private var settings: SettingsStore
    @StateObject private var mediaLibrary: MediaLibraryService
    @State private var appState: AppState
    @State private var showOnboarding = !OnboardingStore.isComplete

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