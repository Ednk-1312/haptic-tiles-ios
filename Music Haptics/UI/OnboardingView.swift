import SwiftUI

/// Short first-launch explanation for testers. It intentionally stays to three
/// cards: what the app is, how to play, and why haptics matter.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let title: String
        let message: String
        let symbol: String
        let tint: Color
    }

    private let pages: [Page] = [
        Page(id: 0,
             title: "Music you can feel",
             message: "Haptic Piano turns music from your library or Files into a four-lane rhythm game. Everything stays on this device.",
             symbol: "music.note.house.fill",
             tint: .pink),
        Page(id: 1,
             title: "Tap the falling tiles",
             message: "Tap anywhere in the matching lane as a tile reaches the line. The game is forgiving about where you touch, but timing still matters.",
             symbol: "hand.tap.fill",
             tint: .cyan),
        Page(id: 2,
             title: "Hear it. Feel it.",
             message: "Core Haptics adds a tactile response to hits, holds, beats, and combo moments. You can tune or disable it anytime in Settings.",
             symbol: "waveform.path.ecg",
             tint: .orange)
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.08, green: 0.04, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                HStack {
                    Label("Haptic Piano", systemImage: "pianokeys.inverse")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }

                TabView(selection: $page) {
                    ForEach(pages) { page in
                        VStack(spacing: 20) {
                            ZStack {
                                Circle()
                                    .fill(page.tint.opacity(0.18))
                                    .frame(width: 156, height: 156)
                                Image(systemName: page.symbol)
                                    .font(.system(size: 58, weight: .semibold))
                                    .foregroundStyle(page.tint)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            Text(page.title)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                            Text(page.message)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.78))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                        }
                        .tag(page.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(maxHeight: .infinity)

                Button {
                    if page == pages.count - 1 {
                        finish()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) { page += 1 }
                    }
                } label: {
                    Text(page == pages.count - 1 ? "Start Playing" : "Next")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .accessibilityHint(page == pages.count - 1 ? "Closes onboarding" : "Shows the next introduction page")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func finish() {
        OnboardingStore.markComplete()
        dismiss()
    }
}
