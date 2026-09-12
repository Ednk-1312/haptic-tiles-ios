import SwiftUI
import UniformTypeIdentifiers

/// Import flow: explainer + system Files picker. Everything stays on-device.
struct ImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("How it works", systemImage: "wand.and.stars")
                        .font(.headline)
                    Text("Pick an audio file. Haptic Piano analyzes it entirely on your device, generates a playable four-lane chart, and lets you feel the rhythm with haptics.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Supported formats", systemImage: "music.note")
                        .font(.headline)
                    Text("MP3, M4A / AAC, WAV, AIFF and other audio Files can decode.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("DRM-protected or purchased Apple Music tracks usually can't be exported as raw audio and won't import.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Privacy", systemImage: "hand.raised.fill")
                        .font(.headline)
                    Text("Your music never leaves this device. No uploads, no accounts, no tracking.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showPicker = true
                } label: {
                    Label("Choose Audio File", systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                if appState.isImporting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Importing, analyzing and charting…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                if let message = appState.importErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("Import Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: showPicker) { _, isPresented in
                if isPresented { appState.importErrorMessage = nil }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.audio],
                          allowsMultipleSelection: true) { result in
                if case .failure = result {
                    appState.importErrorMessage = "The file picker could not open. Try again, or choose a different audio file."
                }
                if case .success(let urls) = result {
                    Task {
                        for url in urls {
                            await appState.importSong(from: url)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}