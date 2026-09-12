import SwiftUI

/// Queue management: Now Playing, Up Next (drag to reorder, swipe to remove),
/// shuffle, repeat one/all, clear, and Play from the queue.
struct QueueView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var playingEntry: QueueEntry?
    @State private var errorMessage: String?
    @State private var playingSession: GameSession?
    @State private var playingRecord: SongRecord?

    var body: some View {
        NavigationStack {
            Group {
                if appState.queue.entries.isEmpty {
                    ContentUnavailableView("Queue is empty",
                                           systemImage: "text.line.first.and.arrowtriangle.forward",
                                           description: Text("Add songs with Add to Queue or Play Next on any song."))
                } else {
                    List {
                        if let now = appState.queue.nowPlaying {
                            Section("Now Playing") {
                                entryRow(now, isCurrent: true)
                            }
                        }
                        Section("Up Next") {
                            ForEach(upNextEntries) { entry in
                                entryRow(entry, isCurrent: false)
                            }
                            .onDelete { offsets in
                                let removed = upNextEntries[offsets.first ?? 0]
                                appState.queue.remove(entryID: removed.id)
                            }
                            .onMove { source, dest in
                                appState.queue.move(fromOffsets: source, toOffset: dest)
                            }
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    shuffleButton
                    repeatMenu
                    clearButton
                }
            }
            .alert("Queue", isPresented: Binding(get: { errorMessage != nil },
                                                 set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
            .fullScreenCover(item: $playingSession) { session in
                if let record = playingRecord {
                    GameView(session: session, song: record, settings: settings)
                }
            }
        }
        .onChange(of: appState.queue.entries) { _, _ in
            // Keep the playing-row binding coherent after mutations.
            playingEntry = appState.queue.nowPlaying
        }
    }

    private var shuffleButton: some View {
        Button {
            appState.queue.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .foregroundStyle(appState.queue.shuffleEnabled ? Color.orange : Color.secondary)
        }
        .accessibilityLabel(appState.queue.shuffleEnabled ? "Shuffle on" : "Shuffle off")
    }

    private var repeatMenu: some View {
        Menu {
            ForEach(QueueRepeatMode.allCases, id: \.self) { mode in
                Button {
                    appState.queue.setRepeat(mode)
                } label: {
                    repeatLabel(mode)
                }
            }
        } label: {
            Image(systemName: repeatIcon)
                .foregroundStyle(appState.queue.repeatMode == .off ? Color.secondary : Color.orange)
        }
        .accessibilityLabel("Repeat mode")
    }

    @ViewBuilder
    private func repeatLabel(_ mode: QueueRepeatMode) -> some View {
        if appState.queue.repeatMode == mode {
            Label(mode.displayName, systemImage: "checkmark")
        } else {
            Text(mode.displayName)
        }
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            appState.queue.clear()
        } label: {
            Image(systemName: "trash")
        }
        .disabled(appState.queue.entries.isEmpty)
        .accessibilityLabel("Clear queue")
    }

    private var upNextEntries: [QueueEntry] {
        guard let now = appState.queue.nowPlaying else { return appState.queue.entries }
        return appState.queue.entries.filter { $0.songID != now.songID }
    }

    private var repeatIcon: String {
        switch appState.queue.repeatMode {
        case .off: return "repeat"
        case .one: return "repeat.1"
        case .all: return "repeat"
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: QueueEntry, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(entry.artist) · \(entry.difficulty?.displayName ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            switch entry.status {
            case .preparing:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Preparing chart")
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Audio unavailable")
            default:
                EmptyView()
            }
            if !isCurrent {
                Button {
                    play(entry)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.subheadline)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.16), in: Circle())
                }
                .accessibilityLabel("Play \\(entry.title)")
            }
        }
        .padding(.vertical, 2)
    }

    /// Starts the queue from this entry: marks it current, builds its session
    /// and presents the game full-screen.
    private func play(_ entry: QueueEntry) {
        appState.queue.setCurrent(entryID: entry.id)
        guard let record = appState.record(id: entry.songID) else {
            errorMessage = "This song no longer exists."
            appState.queue.remove(entryID: entry.id)
            return
        }
        Task {
            let session: GameSession?
            do {
                session = try await appState.session(for: entry)
            } catch is CancellationError {
                return   // superseded by a newer pipeline; entry stays queued
            } catch {
                session = nil
            }
            if let session {
                playingEntry = entry
                playingRecord = record
                // Brief delay so the sheet can dismiss before the cover presents.
                try? await Task.sleep(for: .milliseconds(250))
                playingSession = session
            } else {
                errorMessage = "\"\(entry.title)\" can't be played right now — its audio is unavailable."
                appState.queue.remove(entryID: entry.id)
            }
        }
    }
}