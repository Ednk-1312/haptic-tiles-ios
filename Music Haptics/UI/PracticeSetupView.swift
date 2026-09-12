import SwiftUI

/// Practice configuration sheet: speed, section focus, loop, and HUD options.
/// The chart itself is never touched — this only configures how it's played.
struct PracticeSetupView: View {
    let sections: [PracticeSection]
    let onStart: (PracticeConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var speed = 1.0
    @State private var selectedSectionID: Int?
    @State private var loop = false
    @State private var showScore = true
    @State private var showCombo = true
    @State private var showTiming = false

    private var selectedSection: PracticeSection? {
        selectedSectionID.flatMap { id in sections.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Speed", selection: $speed) {
                        ForEach(PracticeConfig.supportedSpeeds, id: \.self) { s in
                            Text(String(format: "%.2f×", s)).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Audio, notes and haptics slow down together — chart timestamps never change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Speed")
                }

                Section {
                    Picker("Section", selection: $selectedSectionID) {
                        Text("Whole Song").tag(Int?.none)
                        ForEach(sections) { section in
                            Text("\(section.label) · \(Format.duration(section.end - section.start))")
                                .tag(Int?.some(section.id))
                        }
                    }
                    Toggle("Loop Section", isOn: $loop)
                        .disabled(selectedSectionID == nil)
                    if sections.isEmpty {
                        Text("No sections were detected for this song — you can still practice the whole song or use Restart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Section")
                }

                Section {
                    Toggle("Show Score", isOn: $showScore)
                    Toggle("Show Combo", isOn: $showCombo)
                    Toggle("Show Timing Info", isOn: $showTiming)
                } header: {
                    Text("During Play")
                } footer: {
                    Text("Timing info shows accuracy and average timing error at the bottom of the screen. Practice results are never saved as official records.")
                }

                Section {
                    Button {
                        start()
                    } label: {
                        Label("Start Practice", systemImage: "figure.run")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func start() {
        let config = PracticeConfig(speed: speed,
                                    section: selectedSection,
                                    loopSection: loop && selectedSection != nil,
                                    showScore: showScore,
                                    showCombo: showCombo,
                                    showTiming: showTiming)
        onStart(config)
        dismiss()
    }
}