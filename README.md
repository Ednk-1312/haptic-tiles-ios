# Haptic Piano

**"Your music becomes a playable rhythm game."**

Haptic Piano turns songs from your personal Music library into playable rhythm
charts. Pick a song → the app analyzes it entirely on-device, generates a
four-lane chart, and lets you play it — with Core Haptics feedback synchronized
to the audio clock so you can *feel* the rhythm.

- **Primary source: your Music library** via MediaPlayer (MPMediaQuery /
  MPMediaItem). Browse by songs/albums/artists/playlists with local search.
  Songs are identified by their persistent media-library ID, so analysis and
  charts survive relaunch without copying audio.
- **Secondary source: Files import** (MP3, M4A/AAC, WAV, AIFF, …) for audio not
  in the Music library. Files are copied into the app sandbox.
- **Honest, cause-specific audio handling.** iOS only exposes raw audio for
  items the app can reach. DRM-protected, cloud-not-downloaded and
  unknown-unavailable items show distinct states (and distinct explanations) —
  decode failures are never mislabeled as DRM. No DRM circumvention, ever.
- **100% on-device.** No accounts, no uploads, no telemetry.
- **No third-party dependencies.** SwiftUI, MediaPlayer, AVFoundation,
  Accelerate (vDSP), Core Haptics, SwiftData, UniformTypeIdentifiers.

---

## Quick start

1. Open `Music Haptics.xcodeproj` in **Xcode 26 or later** (deployment target **iOS 26.0**; validated with the iOS 26 SDK).
2. Run on a **physical iPhone** — Core Haptics and the Files picker need a
   device; the simulator can build and run the UI but cannot vibrate.
3. On first use, **My Music** asks for Music-library access, then browse/search
   your library (songs, albums, artists, playlists). Tap a song to analyze and
   chart it → **Start Game**.
4. **Import from Files** (the **+** button) remains available as a secondary
   source for audio not in the Music library.
5. **Preview Chart** on a ready song detail scrolls the chart timeline
   (waveform/beats/sections layers, scrub, slow-motion scroll, or playback
   synced to the real audio clock) before you commit to a run.
6. Settings → **Developer → Diagnostics** (Debug builds) shows the analysis and
   chart internals, plus a **Chart quality & patterns** section: detected beats,
   onset candidates charted/skipped, beat-fill notes, final count, notes/second,
   simultaneous max + chord groups, lane-movement histogram (same/1/2/3),
   alternations and extreme-bounce runs.

## Architecture

```
Music Haptics/
├── App/          HapticPianoApp, AppState (analyze → chart pipeline)
├── Models/       SongRecord (SwiftData; source kind + library ID), AudioAnalysis,
│                 MusicalEvent, Chart, Difficulty…
├── Media/        MediaLibraryService (auth, cached queries, search, grouping),
│                 MediaLibraryAudioSource + AudioAccessClassifier (protected vs
│                 accessible), MPMediaLibraryProvider (iOS-only)
├── Audio/        AudioPlayer (audio-clock timeline), AudioImporter, AudioMetadata,
│                 AudioSource abstraction (mediaLibrary | file)
├── Analysis/     AudioAnalyzer (AVAssetReader streaming), OnsetDetector (spectral flux),
│                 TempoEstimator (autocorrelation + octave disambiguation),
│                 BeatTracker (phase search + onset snapping), SectionDetector
├── Chart/        ChartGenerator (importance selection → density control → lane patterns),
│                 ChartValidator (playability gate + repair), ChartDifficultyAnalyzer
├── Game/         GameEngine (orchestrator), InputJudge, ScoreManager, ComboManager, NoteScheduler
├── Haptics/      HapticEngine (CHHapticEngine wrapper), HapticPatternGenerator,
│                 HapticScheduler (beat-aligned rhythm haptics)
├── Persistence/  SwiftData container; charts + analysis as versioned JSON
├── Settings/     SettingsStore (UserDefaults-backed, @EnvironmentObject)
├── UI/           Library (My Music + Imported Files), MyMusic (search, albums,
│                 artists, playlists), Import, SongDetail, ChartPreview (timeline
│                 scrub / slow-motion / audio-synced), Game, Results, Settings,
│                 Diagnostics, ChartDebug (waveform/beats/onsets/notes)
└── Utilities/    Sandbox directories, seeded RNG (SplitMix64), formatting, FFT helper
```

### Music library integration

- **Authorization** (not determined / authorized / denied / restricted) is
  handled up front with an explainer; denied/restricted states point to Files
  import instead of blocking the app.
- **One query, local search.** The library is snapshotted once per
  authorization/refresh into lightweight `LibrarySong` models; search filters
  the cache locally (no MPMediaQuery per keystroke).
- **Browse controls (Songs tab).** Sort by Title / Artist / Album / Duration /
  Recently Added / Recently Played / Difficulty (hardest first, unanalyzed
  last; every sort is deterministic with title + persistent-ID tie-breaks).
  Filters: audio available / unavailable, analyzed / not analyzed / chart
  ready, and a difficulty-score range. Search also applies to the Albums,
  Artists and Playlists tabs (group title, artist, playlist name, or any
  member song). Artwork goes through an NSCache keyed by persistent ID +
  size, and `MPMediaItem` objects are retained only in a side table for
  artwork — the sort/filter pipeline itself runs on pure snapshots
  (`MusicLibraryFiltering`), fully covered by `MusicLibraryFilteringTests`
  (search, every sort, every filter, combined filters, determinism, and a
  10k-song path).
- **Persistent ID is the cache key.** `SongRecord.mediaLibraryID` ties charts
  and analysis to the library item across relaunches; audio is never copied.
- **Audio resolution.** `AppState.resolveAudioURL` returns the sandbox copy for
  files or the item's `assetURL` for library songs. `MPMediaItem.assetURL` is an
  `ipod-library://` URL (not a file path), so only genuinely unreachable items
  (DRM / not-downloaded / no URL) resolve to nil; anything with a URL is handed
  to the analyzer, which reports decode failures with exact NSError detail
  instead of a generic message. One URL feeds analysis, playback, and the game
  clock.
- **Audio diagnostics.** The Developer section of each song detail runs a full
  probe (`AudioProbe`): MediaPlayer flags (hasProtectedAsset / isCloudItem /
  assetURL/scheme/path), AVAsset duration + tracks, AVAssetReader creation /
  start / sample reads, and AVAudioPlayer load — each step reporting the exact
  NSError domain/code on failure. Results also print to the Xcode console and
  run automatically in Debug when a library song's pipeline fails.
- **Metadata is kept separate.** Library BPM (`libraryBPM`) and DSP-detected
  BPM (`tempoBPM`) are stored side by side and never overwrite each other.
- **Tests.** `AudioSourceTests` covers the classifier with a mocked library
  provider: accessible, downloaded-cloud-with-URL (resolvable), protected
  (DRM flag), cloud-only (no URL), unknown-unavailable, missing, and file
  sources — proving DRM, cloud state and URL presence stay separate.

### Key technical decisions

- **Gameplay clock = audio hardware clock.** `AudioPlayer` anchors
  `AVAudioPlayer.deviceCurrentTime` to the audio timeline; `Date()` is never
  used for gameplay timing. Interruptions, route changes (headphones unplugged)
  and media-server resets pause safely; the game resumes via explicit user action.
- **Forgiving, whole-lane input.** The entire lane is the touch target (no
  pixel-perfect aiming); judgment reads the audio clock on touch-down, accepts
  up to GOOD + 40 ms edge-grace as GOOD instead of a phantom MISS, and prevents
  re-hitting judged notes. Default windows are the forgiving ±70 / ±130 / ±200 ms.
  Debug console prints a per-tap trace: `[Input] lane / touch X-Y / note lane &
  time / audio time / Δ ms / judgment`. Note travel is BPM-aware: lead time =
  base × (beat interval / 0.5s), clamped to 0.9…2.4 s so fast songs stay readable.
- **Balanced lane usage.** The lane assigner alternates fresh pairs, then
  *migrates* after a short pair-run, and after a warm-up applies per-lane usage
  pressure — a constant groove no longer loops on the right-hand pair. Charts
  show per-lane shares/counts/idle windows and a one-sided flag in Diagnostics.
- **Streaming analysis.** `AudioAnalyzer` decodes via `AVAssetReader` (uniform
  handling of MP3/AAC/WAV/AIFF) and keeps only compact feature arrays (spectral
  flux, RMS, band energy) — never the full waveform. FFT is Accelerate/vDSP with
  reused buffers.
- **Tempo** uses autocorrelation of the onset envelope with a musical prior to
  resolve octave ambiguity (70 vs 140 BPM); confidence comes from peak
  prominence. Beats are a phase-optimized grid snapped toward strong onsets.
- **Charts are designed, not transcribed (v4 phrase composition).** The
  detected beat grid is cut into 4-beat phrases; each phrase picks a RHYTHM
  TEMPLATE (quarters, eighths, syncopation, bursts, call-and-response,
  deliberate rests) and a LANE MOTIF (walk, alternation, center, staircase,
  mirror) from a deterministic seeded roulette over what the music actually
  supports — repeating musical material reuses its template with lane
  variation, fresh material gets fresh rhythm. Rests are first-class: quiet
  sections deliberately breathe. Three seeded candidate arrangements are
  generated and the best one wins via a penalty-based quality score (reaction
  time, chord-aware min-distance jumps, lane balance, dead air, repetition,
  rest placement). Section-aware density follows detected energy
  (intro sparse → chorus dense → breakdown reduced), downbeats and accents are
  preserved, chords only on supported downbeats at Medium+, and holds only on
  strong-beat accents with room in their own lane. Higher difficulties add
  weak-subdivision pushes up to a strict budget; the validator remains the
  final authority and repair is near-zero on well-shaped candidates.
- **Chords are real.** The validator and repair treat notes within 0.1 s as
  ONE musical event (a chord): spacing/jump rules apply between chord groups
  using min-distance lane sets, so two-voice chords survive validation and
  reach the player instead of being repaired away.
- **Playability is enforced.** `ChartValidator` checks spacing, density
  (chord-group aware), simultaneity, lane jumps, same-lane repeats and
  difficulty spikes; the generator repairs or retries with a different seed
  before accepting a chart. Beat-less/ambient material still charts via the
  v3 per-cell fallback (with a fixed fill budget that no longer starves
  sparse songs).
- **Haptics are timing-sensitive.** Hit haptics fire at hit time; "feel the
  beat" rhythm haptics are scheduled only ~350 ms ahead of the audio clock and
  fully rebuilt on pause/seek so stale patterns never play.
- **Concurrency.** The project uses Swift's "approachable concurrency" (default
  MainActor isolation). Everything that can be heavy — analysis, chart
  generation, file I/O — is `nonisolated`/`async` and runs off the main thread.
- **Persistence.** Songs are SwiftData metadata; analysis and charts are
  versioned JSON (`ChartStorage.chartVersion`). Charts survive relaunch and are
  regenerated when the version bumps (currently **v4**; the bundled Core ML
  models are retrained against v4 charts — `swift run TrainingExport` +
  `AI/Training/train.py`).
- **One analysis, five charts.** Each song is analyzed ONCE; that analysis
  produces independent Easy / Normal / Hard / Expert (and experimental
  Extreme) charts with separate IDs (`songID.chart.<difficulty>.json`), so
  difficulty changes selection, density, rhythm, movement, chords and holds —
  never just note speed. Charts are cached per difficulty and regenerated only
  when the analysis or generator version changes. The song detail screen picks
  a tier and shows its difficulty score, note count and notes/sec; chart
  preview/debug views load the selected tier, and monotonicity diagnostics
  flag significant Easy > Hard inversions (rare rating crossings are handled
  gracefully).

### Chart-quality report tool

`swift run ChartStats` regenerates 21 deterministic charts (7 musical profiles ×
3 difficulties) through both the v3 legacy selector and the v4 phrase
composer on identical inputs and prints a before/after table: notes, NPS,
quality score, rests, chords, holds, lane balance, repairs, difficulty variance
and per-section density. Current numbers (see `LogicTests/Sources/ChartStats`):
v4 raises quality 9.15 → 9.24, chord frequency 0.29 → 0.45, holds 0.06 → 0.07,
rest frequency 0.05 → 0.07, with zero validator repairs and zero failed charts
in both modes.

### Settings & calibration

Timing calibration (`-100…+100 ms`) is applied **only to judgment**, never to
chart timestamps. Sign convention: `delta = tapTime + offset − noteTime`; if
your hits register **late** (audio output latency), lower the offset (more
negative); if they register early, raise it.

Judgment windows default to Perfect ±50 ms, Great ±100 ms, Good ±175 ms — all
configurable in Settings.

**Interactive calibration** (Settings → “Calibrate by tapping”): a short
metronome exercise (4-beat count-in + 12 measured beats, 90 BPM) where the
player taps along with a flashing cue (haptic ticks included when enabled).
Each tap is matched to its nearest unconsumed cue; the recommended offset is
the **negated median** of the measurements, rounded to 5 ms and clamped to
±100 ms — never a single tap. Taps beyond the acceptance window or double-taps
on a consumed cue are rejected and counted. Apply / discard / manual stepper
(±5 ms steps). This measures the player's *perceived* sync, not laboratory
latency, and never touches chart timestamps. Exercise flow is simulated
deterministically in `CalibrationTests` (perfect / late / early taps, outlier
robustness, rejection rules, min-measurement gate, clamping).

### Real-device timing validation (Debug builds)

During gameplay, the **scope button** (top right) toggles a live overlay: audio
clock position / song duration, per-frame render cadence (frame · avg · max,
measured with a monotonic uptime clock — never used as the gameplay clock),
countdown to the next unjudged note, the configured calibration offset, and the
mean measured per-hit timing error plus the most recent hits (note timestamp,
actual tap time, Δ in ms). Every judgment also prints `[Timing] …` lines to the
console, and start/pause/resume/restart/finish print audio-clock anchor events
so clock discontinuities are visible. A Debug `Audio Diagnostics` probe for
library songs lives in each song's Developer section. The authoritative
gameplay clock is always `AVAudioPlayer.deviceCurrentTime`, anchored at
play/resume; wall clock is never used for timing.

### Simulator autoplay (Debug builds)

The **play button next to the scope button** in the gameplay HUD toggles a
developer autoplay mode: notes are hit automatically the instant their
timestamp arrives on the REAL audio clock, through the exact same
tap→judgment pipeline as physical touches (nearest-note resolution,
classify-forgiving windows, score/combo, haptics). Judgments therefore come
back ideal and a full chart plays through to the results screen without input
— the way to exercise gameplay on a simulator. A yellow `AUTOPLAY` badge shows
while active; the mode survives pause/resume/restart and only exists in Debug
builds (production timing is never faked).

For deterministic whole-chart validation without audio, `AutoplaySimulation`
drives the real `NoteScheduler`/`InputJudge`/`ScoreManager` with a scripted
clock: perfect, early-biased, late-biased, seeded-noisy and note-dropping
players, all returning a real `GameplayResult` (this is also the foundation
for the roadmap's automated gameplay-simulation suite).

### Demo song + `-demoAutoplay` (Debug builds)

A **Demo Song · Autoplay** button in the Library's Developer section
synthesizes a ~28 s, 120 BPM groove (kick/snare/hats/bass/chord stabs) to a
WAV in the sandbox (`DemoSongFactory`), then runs it through the REAL
pipeline — analysis, chart generation, gameplay with autoplay enabled. The
same flow triggers automatically on launch with the `-demoAutoplay` launch
argument, which is how the whole game loop (four lanes, holds, chords,
score/combo, judgment feedback, results) can be exercised and screenshotted
on a simulator with zero input. Add `-demoDifficulty easy|normal|hard|expert|extreme`
to pick the difficulty tier (default hard).

### Haptic profiles

The Core Haptics system is profile-driven (Settings → Haptics → Profile):

- **Minimal** — quiet single-tap hits only; no beats, accents or section
  ticks (the most conservative profile).
- **Musical** — balanced hits (double-tap Perfects), subtle beat/accent/
  section feedback (the default).
- **Strong** — firm everything: loud hits, bold beats, strong accents.
- **Beat Focused** — lighter taps, prominent beats and accents so the rhythm
  itself is what you feel.

Each profile pre-bakes intensity/sharpness for note hits per judgment, holds
(start + completion double-pulse), chords (one firm pulse on the first voice
— never per-voice), weak/strong beats, accents and section changes.
`HapticScheduler` schedules beats, strong accents and section boundaries at
their EXACT chart time via the engine's at-delay scheduling (previously beats
fired up to 350 ms early — a real timing bug this system fixed), resyncs on
seek/jump, and is torn down on pause/restart/song change so stale haptics
never survive a transition. A global per-profile **cooldown**
(`HapticCooldown`, 25–70 ms) is the anti-stack guard — dense passages can
never buzz the device, and `HapticEngine` remains strictly best-effort
(unsupported hardware, engine resets/interruptions and playback failures are
always silent; gameplay never waits on haptics). Existing controls remain:
haptics on/off, reduced mode (softer hits, no miss feedback), strength slider
and the feel-the-beat master switch. Covered by `HapticPatternTests` +
`HapticProfileTests` (15 deterministic tests: judgment ordering across all
profiles, settings gating, category disabling, profile strength ordering,
cooldown boundaries/reset, determinism).

### Hold notes

Charts now include holds: `HoldGenerator` converts a small, seeded fraction of
strong-accent notes (strong beat + real section energy + free space in their
own lane) into holds of one or two beats, so every chart is deterministic for
the same input. `ChartValidator` enforces hold-aware same-lane rules (the next
note must clear the TAIL plus the same-lane gap; overlap is a hard failure and
`repair` drops violators). In gameplay, a hold head is judged like a tap, then
the finger must stay down until the tail on the audio clock: completion awards
`500 × multiplier` bonus points with a `+HOLD` popup, early release breaks the
combo (counted as `holdsMissed`), pausing forfeits the bonus without breaking
the combo, and autoplay sustains holds automatically. `GameplayResult` carries
`holdsCompleted`/`holdsMissed`, shown on the results screen.

### Practice mode

Any generated chart can be practiced **without touching the chart itself**: the
song detail screen's **Practice** button opens a setup sheet (speed, section,
loop, score/combo/timing visibility) that wraps the SAME cached chart and
analysis in a `PracticeConfig`. The authoritative audio clock advances at the
chosen rate (`AVAudioPlayer.enableRate`, re-anchored on every change so time
stays continuous), so audio, falling notes, judgments and haptics all slow
together — 0.50× / 0.75× / 1.00×, extendable via
`PracticeConfig.supportedSpeeds`. Detected song sections (Intro, Breakdown,
…) become selectable practice windows: `NoteScheduler` gains a time window so
out-of-section notes are nonexistent (never miss, never render, never match a
tap), and jumps seek the audio, rebuild the scheduler, and fully reset
score/combo/judgments/holds/haptic schedule — nothing leaks between sections.
Looping restarts the section automatically at its end with the same full
reset. An in-game practice bar (speed / section / loop / restart / timing)
sits above the progress bar; the pause menu gains **Restart Section**; the
live timing line shows accuracy, mean |timing error| and P/G/M counts
(`PracticeStats`, never saved as an official record). Score/combo can be
hidden for scoreless reps. Demo autoplay accepts
`-demoPracticeSpeed 0.5 -demoPracticeSection N -demoPracticeLoop` to exercise
practice at any speed in the Simulator.

### Reliability & stability

A dedicated hardening pass keeps the app predictable under bad data and
unexpected states:

- **Session identity.** Every analysis/chart-generation run gets a per-song
generation id; tasks verify they are still the LATEST run (and that the song
still exists) before touching any state, so reanalyzing, regenerating or
deleting a song mid-flight can never be overwritten by stale callbacks.
- **Playback state machine.** `AudioPlayer` models idle/loading/playing/paused/
failed explicitly; `pause()`, `stop()`, `seek()` and `play()` are idempotent
and safe from any state; `GameEngine.start()` tears down an active session
before restarting so exactly one playback session ever exists. Audio-session
interruptions and route changes pause cleanly (no auto-resume surprise).
- **Chart safety layer.** The generator sanitizes every output chart before it
can be persisted or played (drops NaN/Infinity/negative/beyond-song/bad-lane
notes, clamps, re-ids, sorts), and `ChartValidator` hard-rejects malformed
notes up front (NaN comparisons are always false, so they were previously
silently passable). Cached charts that fail to decode or fail structural
checks are discarded and regenerated instead of surfacing dead-end errors.
- **AI can't break gameplay.** Model outputs are clamped and validated before
fusion (NaN/Inf/negative/>10 difficulty never reach a chart); any model
failure falls back to the deterministic system.
- **Solid, high-contrast UI.** Liquid-glass materials (`.ultraThinMaterial`,
`.regularMaterial`) were removed from gameplay controls, pause and results in
favor of opaque surfaces with clear borders — the note stream stays the
brightest element, and the artwork background remains.
- **Error recovery, not dead ends.** Failed analysis shows a Retry button;
protected/removed library songs explain the exact cause (DRM vs iCloud vs
gone-from-library) and point to Files import; missing/corrupt caches
regenerate.
- **Touch input hardening.** A lost touch-UP (system cancellation) can no
longer wedge a lane: a new touch arriving long after the last event is treated
as a fresh gesture.
- **`ReliabilityTests`** (16 deterministic tests): chart sanitizer, validator
malformed gate, AI fusion clamping/fallback, corrupt cache-file recovery,
version-mismatch handling, restart cleanliness (no stale judgments),
double-judgment prevention, song A→B→A stress isolation, dense-chart
judge-every-note-exactly-once, pathological generator inputs (silence, zero
beats, duration 0, BPM 20/400, NaN events) and a real `AVAudioPlayer`
state-machine test (double pause/stop, seek, monotonic clock).

### Queue + automatic song transitions

Any song (Music library or imported file) can be queued from its detail screen
via **Add to Queue** (appends) or **Play Next** (inserts after the current
song). The queue lives in `QueueManager` — a pure, seeded state machine with
per-ENTRY ids (two entries may share one song at different difficulties), drag
reorder, remove, clear, shuffle, Repeat One and Repeat Queue, persisted to
`queue.json` and restored on launch (entries whose songs were deleted are
dropped safely; the current entry is repaired). `QueueView` (toolbar button in
the Library) shows Now Playing / Up Next with per-entry chart status.

When a song ends, the game saves the result, fully tears down the session
(haptics, touches, holds, scheduler), loads the next entry's cached chart and
starts it cleanly — nothing leaks across songs. The next-next entry is
pre-generated in the background while the current song plays, gated by
preparation tokens so removing/advancing past an entry cancels its work, and
cached charts are never re-analyzed. Repeat One replays the same chart (skip
escapes it); with the queue exhausted, the results screen shows normally.
`GameplayResult` files persist per song in `ResultsStorage` (results screen
shows the best score for the song+difficulty). Demo autoplay: launch with
`-demoAutoplay -demoQueue` to watch the same song queue easy → expert and
transition automatically in the Simulator.

### Local playlists

Fully local playlists (no accounts, no cloud): a **Playlists** section on the
home screen lists playlists with a 4-up artwork collage, song count and total
duration (resolved live — songs that later disappear are counted as
unavailable, never crash). `PlaylistManager` is a pure, versioned state
machine persisted to `playlists.json`: create / rename / delete, add songs
deduped within a playlist (the same song may appear in MANY playlists),
remove, drag reorder, and a seeded-deterministic shuffle order. Songs are
referenced by stable record IDs, so both My Music songs and imported files
work, and app-side song deletion cleans them from every playlist
automatically. The playlist detail screen offers **Play** (queues the whole
playlist and starts the first song — the queue's auto-transition plays the
rest), **Shuffle** and **Add to Queue**, plus an add-songs picker covering My
Music + imported files. Restore repairs legacy files (nameless playlists
dropped, duplicates deduped) and rejects newer schemas instead of misreading
them.

### Local statistics

Every finished run feeds a fully local statistics system (`stats.json`,
versioned — nothing ever leaves the device). `StatsManager` keeps per-song
rollups AND per-difficulty records (Easy/Expert are never mixed): attempts,
highest score, best accuracy, highest combo, cumulative Perfect/Great/Good/
Miss counts, best holds, best difficulty cleared, last played, and total play
time (measured from the authoritative audio clock at finish). After a run,
personal records — New High Score / Best Accuracy / Best Combo / Best
Difficulty, each with old → new values — appear as trophy badges on the
results screen. A Statistics screen (home screen entry) shows global
aggregates (songs played, attempts, notes hit/missed, overall accuracy,
highest combo, hardest chart cleared, total gameplay time) plus a per-song
per-difficulty breakdown; the song detail screen shows the per-song summary.
Corrupt/newer-schema files restore to an empty state and invalid counters are
repaired on load; deleting a song removes its statistics (a re-imported song
starts fresh). Practice and developer-autoplay runs are never recorded as
official results — this pass also fixed a pre-existing gap where standalone
plays (outside the queue) never persisted results at all.

### Chart preview

The song detail screen's **Preview** button opens the generated chart before
play: a header (artwork, title, artist, detected BPM, difficulty, note count,
notes/s, duration), an in-place **difficulty switcher** (Easy→Extreme reloads
that tier's chart), a stats card (difficulty score, NPS, simultaneous max,
chords, beat-fill, onsets charted, holds, rests, quality), and a timeline that
renders the SAME chart data gameplay uses — four lane rows, waveform, detected
beats, section shading — with drag-to-scrub, zoom, simulated slow-motion
scroll, and real audio-synced playback when the song's audio is accessible
(the playhead then follows the audio clock). Section chips jump to any
detected section (audio seeks too). A **Chart check** card surfaces suspicious
properties — excessive density, lane imbalance, huge jumps, repetitive 1↔4
runs, difficulty spikes, heavy chords — compactly in normal mode. The
**Developer** toggle (Debug builds) overlays onsets, candidate events with AI
importance, selected-event rings, section boundaries and colored lane-
transition connectors. Simulator: `-demoPreview` opens the preview for the
demo song.

### Chart editor

The song detail screen's **Edit** button opens a lightweight rhythm-chart
editor (not a DAW) over the same chart data gameplay uses. Tap an empty lane

### Run analytics

Every finished run (results screen) and every saved replay (timing
inspector) can open a **Run Analytics** screen computed locally from the run's
replay events — nothing is transmitted. It shows the game's own weighted
accuracy (Perfect 1.0 / Great 0.75 / Good 0.5 / Miss 0 over the judged
notes, exactly mirroring `ScoreManager.counts`), mean absolute + signed
timing error, an early/accurate/late breakdown (|±15 ms| threshold),
Perfect/Great/Good/Miss distribution bars, score and combo sparklines, a
24-bucket **timeline strip** colored early (red) / accurate (green) / late
(blue) / no-notes (gray), and a **per-section breakdown** (accuracy, |err|,
E/A/L counts for every detected section, plus an "Other" row for events
outside all sections — never assumed covered). The pure `RunAnalyticsCalculator`
is covered by `RunAnalyticsTests` (14 deterministic tests: accuracy formula,
hold lifecycle counting, early/late classification, progression series,
bucket boundaries and aggregation, section stats, zero-duration edge case,
and input determinism).

### Replays

Every finished **normal run** (never practice or developer autoplay) is
recorded compactly as gameplay events — note ID, lane, chart time, judgment,
timing error, score, combo, hold lifecycle — a 93-event run is ~19 KB of
versioned JSON (`ReplayStorage`, schema v1; corrupt files are purged,
future-version files are refused and kept). The results screen offers **Save
Replay** and then **View Replay**: a four-lane playback that re-injects each
event at its chart timestamp on the SAME audio clock live gameplay uses, so
replays are deterministic (scrub/seek re-consume events from the start and
always land on the same score/combo). If the original audio is gone (deleted
import, revoked library item) playback falls back to a clearly-labeled wall
clock with identical chart-relative timing. A timing inspector lists every
event (time, kind, judgment, ±ms, score, combo) and jumps to it on tap; the
playback view refuses a replay whose song/difficulty/chart version no longer
matches the stored chart. `ReplayTests` covers builder normalization,
save/load round-trip, corrupt/future-version/missing files, chart matching,
song filtering, deletion, purge, compactness, and deterministic
re-consumption. DEBUG `-demoReplay` builds a perfect replay of the demo
song's chart and opens the player for Simulator verification.

### Chart editor

The song detail screen's **Edit** button opens a lightweight rhythm-chart
editor (not a DAW) over the same chart data gameplay uses. Tap an empty lane
to add a note, tap a note to select it (chord-aware: a tap selects every
simultaneous voice), drag to move it in time and lane, and use the toolbar
for hold mode (tap adds a hold; a selected hold gets a duration slider),
chord voices (adds the next free lane at the same time), delete, undo and
redo. The beat grid comes from the detected beat track with a Free / 1/4 /
1/8 / 1/16 snap picker — snapping only applies when the edit is within ~45ms
of a grid point, so fine manual timing is never forced. The SAME playability
validator as generation runs on every mutation and shows issues inline (red
hard failures, orange warnings) without blocking the editor.

Edited charts are **versioned and never overwrite the generated chart**: they
save as a separate `*.edited.chart.json` with the editor schema version and
the generated chart version they were based on (newer schemas are ignored,
never misread). Gameplay and preview prefer the edited variant while it
exists; **Regenerate** and **Discard edits** both confirm first, and a
modified/Generated header badge tracks whether the working copy differs from
the baseline. The difficulty score is recomputed from density/chord changes
against the generated baseline.

### Artwork-driven background

`SongBackgroundThemeFactory` analyzes each song's artwork ONCE (cached by
artwork bytes via `NSCache`) into a pure, deterministic palette
(`ArtworkPaletteAnalyzer`, UIKit-free and unit-tested): dominant and secondary
colors (hue-family clustering), accent (most saturated pixel), brightness,
saturation and warm/cool tendency. The theme drives a multi-layer
environment: blurred artwork, an enlarged/cropped **hero layer** whose
opacity/scale/offset follow the section energy, an extracted-color gradient
wash that interpolates between **quiet** (desaturated/dark) and **energetic**
(brighter/more saturated) variants of the palette, corner accent lighting, a
deterministic per-song **particle field** (16 seeded particles; drift speed
and opacity scale with energy), vignette, and readability gradients. Music
reactivity is restrained by design: only **strong** beats pulse the backdrop
(weak beats barely register — no constant flashing), high-energy sections
raise lighting gradually (0.9 s animation), quiet sections reduce motion, and
section transitions evolve the tint slowly (1.4 s animation on the section
index). Notes always stay the brightest layer. Songs without artwork (or
failed analysis) get a **deterministic seeded fallback** theme — hue derived
from the song's stable UUID FNV hash — so the game never shows a broken
image and the same song always gets the same environment.

### Fullscreen gameplay presentation

`GamePlayfieldView` draws four edge-to-edge columns with permanent identity
colors (cyan/blue, pink/purple, lime/green, orange/red), tinted lane bands,
clearly visible dividers and lane numbers, so the four columns are
unmistakable on any artwork. Tiles are ~92% of their lane width and tall;
holds render as long vertical tiles whose length IS the musical duration
(active holds pulse, completed holds flash). The hit region is huge: per-lane
tinted catch zones, chevron markers and a glowing full-width hit line.
Judgment feedback pops in large with an outline pass plus expanding hit rings;
lane flashes are per-lane colored; the HUD has a 42-pt score, a combo capsule
with multiplier chip and a top scrim for readability. Note positions remain
pure math on the audio clock — never animation completion.

## Performance

Measured with `PerfBenchTests` (`swift test --filter PerfBenchTests`), which
prints `BENCH` lines; all timings below are **Release** builds of the logic
package on macOS (an Apple Silicon Mac ≈ a physical iPhone in per-core
terms).

| Metric | Before | After |
|---|---|---|
| Audio analysis, 10-min WAV (decode + DSP) | ~13.2 s (Debug) | 219 ms (Release; ~2,700× realtime) |
| Chart generation, 10-min song × 4 difficulties | **10.8 s (Debug)** | 85 ms (Release; 3.7× faster in Debug: 2.9 s) |
| Chart generation scaling, 1→10 min | superlinear (144 ms → 10.8 s) | near-linear (61 → 2,949 ms Debug; 8.5 → 85 ms Release) |
| Gameplay 60 Hz sim over a 10-min chart (36,000 frames) | 69 ms | 70 ms (already negligible: ~2 µs/frame) |
| My Music filter+sort, 50k songs | 102 ms | 102 ms (already sub-frame for a deliberate action) |
| Artwork palette, 24×24 sample | 0.6 ms | 0.6 ms (full-size 512² synthetic: 245 ms, never on the hot path) |
| Chart save/load ×100 · queue snapshot ×50 · reorder ×200 | 45 / 266 / 615 ms | unchanged |

### What was optimized (behavior-identical)

- **Chart generation was quadratic** — the onset-support projection loop was
  O(grid ticks × musical events): ~9,600 ticks × 4,000 events for a 10-minute
  song. Both lists are time-sorted, so it is now a single sweep
  O(ticks + events + matches) with identical accumulation order — every
  determinism test still passes byte-identical.
- The per-phrase `active.map { $0.event }` allocation in pattern selection was
  hoisted out of the phrase loop (300+ phrases × 4,000 events of copies
  removed).
- **Audio analysis hot loop**: the per-hop `Array(pending[...])` copy (a
  2,048-float allocation per FFT hop, ~46k× on a 10-minute song) is gone —
  the FFT window is read straight from the pending buffer via
  `UnsafeBufferPointer`. Per-hop `removeFirst` (a full-array memmove every
  hop) became per-chunk compaction with an offset counter.
- **Gameplay loop**: the 60 Hz tick no longer allocates a `Task` per frame
  (~60 allocations/s of gameplay) — the timer closure calls `tick()` directly
  under `MainActor.assumeIsolated` (it already ran on the main run loop).
- **Queue pre-generation**: a restored queue of hundreds of entries now runs
  through a 3-slot `PreparationLimiter` actor instead of spawning hundreds of
  simultaneous analysis pipelines — gameplay always wins the CPU/memory
  budget.

Analysis time is dominated by the FFT + decode (the array-copy removals
showed ~no change there — the cost was already in vDSP, which is correct);
the measurable wins are chart generation and per-frame gameplay
allocations. All DSP/chart/timing behavior is unchanged.

## Running the tests

The repo has a real Xcode unit-test target (`Music HapticsTests`) plus a
SwiftPM package (`LogicTests/`) that compiles the same platform-neutral sources
via symlinks and runs them on macOS:

```bash
cd LogicTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```

Coverage: BPM estimation (incl. octave ambiguity), onset detection, chart
generation determinism + playability, validator repair (incl. hold-tail
same-lane rules), hold-note generation (determinism, accent gating, occupancy),
hold scoring and simulated sustain/early-release, difficulty scoring,
judgment windows + calibration, scoring/combo/accuracy, haptic pattern
generation, audio-source accessibility classification (accessible / protected /
cloud-with-URL / cloud-only / unknown-unavailable / file), an end-to-end
analyzer test on a synthetic metronome WAV, and a chart-quality suite across
musical characteristics (drum-heavy, 220 BPM dense, sparse vocal, quiet/loud
sections, beat-less fallback) asserting playability, density caps, deliberate
selection (never onset dumps), accent preservation, difficulty-monotonic
spacing and determinism. The autoplay-simulation suite replays whole charts
through the real scheduler/judge/scoring path with perfect, early-, late-,
seeded-noisy and note-dropping players and checks score/combo/accuracy math
against an independent recomputation, full-song judgment coverage, calibration
participation and results-record integrity.

## Intelligent Tempo Analysis

Tempo estimation has a capability-gated, two-tier preprocessing pipeline. Every device retains the existing Accelerate/vDSP DSP estimator as the reliable baseline; no tempo analysis runs during active gameplay.

- **Standard Math / DSP fallback:** `TempoEstimator` analyzes the compact spectral-flux envelope with autocorrelation, harmonic support, octave disambiguation, confidence, and windowed stability checks. This path works offline on every supported device.
- **Enhanced on-device tier:** `TempoAnalyzerDeviceCapabilities` checks the OS-reported Foundation Models availability, Core ML support, and the presence of a validated bundled `AITempo` model. It does not infer eligibility from an iPhone model name and it never treats Foundation Models availability alone as proof that a tempo model exists.
- **Model boundary:** `IntelligentTempoAnalyzer` receives compact flux features only, ranks half/normal/double-time candidates, and rejects missing, ambiguous, low-confidence, or invalid predictions. The validated `AITempo.mlmodel` is bundled and compiled into `AITempo.mlmodelc` by Xcode. If the model fails or confidence is insufficient, the analyzer returns the DSP result with an explicit fallback reason.
- **Stable integration:** one validated BPM, confidence, stability, and tempo-change result is passed to the existing beat tracker and chart generator. Dynamic Speed consumes that prepared result; it is never re-estimated frame by frame, and scoring timestamps/audio timing are unchanged.
- **Local cache:** cache keys include the source URL, sample rate, duration, compact signal fingerprint, analyzer kind, and analyzer version. Version mismatches and analyzer changes invalidate entries. Cache hits/misses and optional inference duration are surfaced in Debug diagnostics.
- **Privacy/performance:** processing is local with AVFoundation + Accelerate + optional Core ML only; no audio, identity, or telemetry is uploaded. Analysis runs before play, uses bounded feature arrays, and exposes measured wall/inference duration rather than unverified battery or Neural Engine claims.
- **Settings:** Settings → Enhanced Tempo Analysis enables the capability-gated path when it is genuinely available; unsupported devices show that the DSP fallback remains active and fully playable offline.

## On-device AI (Version 1)

The app ships small **real** Core ML models that run on-device (no network,
no server):

- `AIDifficulty.mlmodel` (approximately 96 KB) — 16 normalized chart/music
  features → predicted difficulty 0–10. Version 2 was retrained against the
  corrected action-based difficulty metric; held-out evaluation: MAE 0.0757,
  RMSE 0.1194, correlation 0.9942 versus the deterministic difficulty.
- `AIEventRanking.mlmodel` (approximately 226 KB) — 16 normalized per-event
  features → importance 0–1 for chart-selection value. Version 2 held-out
  evaluation: AUC 0.9153, precision 0.3921 / recall 1.0 at 0.5, 80.5 %
  agreement with the deterministic chart's own selection.
- `AITempo.mlmodel` (42 KB) — 12 normalized onset-envelope features rank
  half-time, normal-time, and double-time BPM candidates. Held-out,
  song-disjoint validation on 2,400 deterministic synthetic songs produced
  1.000 top-1 candidate accuracy versus the 0.325 DSP candidate baseline
  (MAE 0.05956, RMSE 0.15387). This model is an analysis aid, not a gameplay
  controller; the stable DSP result remains the fallback.

The difficulty and event models are `GradientBoostingRegressor` tree ensembles
converted from the reproducible Python training pipeline
(`AI/Training/train.py`) and compiled into the app bundle by Xcode (`coremlc`).
The separate `AITempo.mlmodel` is documented in the Intelligent Tempo Analysis
section above. These are tiny numeric regressors that run through Core ML, not
Foundation Models/Core AI, and they are optional advisory layers over the
Standard Math Engine.

### Event ranking (candidate selection)

The event model ranks every candidate musical event for chart-selection value
via a 16-feature vector: time position, onset strength, onset confidence,
low/mid/high band energies, beat strength, on-beat flag, distance to the
nearest beat, local event density, previous/next neighbor spacing, section
energy, section label factor, and the deterministic DSP importance itself
(schema frozen by a golden-vector test). `AIEventFusion` blends DSP + AI
importance with a **decisiveness heuristic** (`2·|p − 0.5|`) as the
confidence/uncertainty signal: below the floor, or when the model is missing
or returns non-finite values, the DSP importance passes through unchanged
(deterministic fallback). The fused scores only re-rank the *existing*
candidates — the AI can never create timestamps, and the chart still goes
through the deterministic generator, density caps and the playability
validator, so even an adversary that ranks everything at 1.0 cannot exceed a
difficulty's notes/sec cap (tested).

Developer diagnostics (Diagnostics → Event ranking) show per-event DSP / AI /
final importance, selected vs rejected, confidence, used-AI flag, the batch
inference time, aggregate fallback count and average confidence — plus JSONL
export for training data.

**Framework choice — Core ML, not Core AI.** The tempo model is a compact
12-float-in/1-float-out candidate ranker. Xcode compiles the source model into
`AITempo.mlmodelc`; the regression test loads that exact built bundle artifact
and executes inference. The app measures inference duration at runtime rather
than claiming an unmeasured latency, battery, or Neural Engine figure.

**How the AI is used (intelligence, not control).** The AI is an advisory port
(`AIChartAdvisor`) into the deterministic pipeline: it re-ranks candidate
musical events *before* the same beat-grid selection, and it fuses the final
difficulty number (default weight 0.3 AI / 0.7 deterministic; configurable,
with a confidence floor). It cannot create timestamps, cannot exceed the
density/playability caps, and never bypasses `ChartValidator`. If a model is
missing, fails, or predicts at low confidence, the chart is byte-identical to
the deterministic output. Charts record `aiModelVersion`; chart version 3
invalidates pre-AI caches.

**Confidence is honest.** Difficulty confidence is a disagreement heuristic
(`1 − |Δdet−ai|/3`) and event confidence is a decisiveness heuristic
(`2·|p−0.5|`) — labeled "heuristic, not calibrated" in the UI. Neither is
presented as a calibrated probability.

**Training data.** `LogicTests/Sources/TrainingExport` (SwiftPM executable)
runs the REAL pipeline (synthesis → `ChartGenerator` → difficulty analyzer →
feature extractors) over 90 seeded songs × difficulty/density combos and writes
JSONL labels: 1,080 difficulty records and ~245,000 event records where the
label is "the deterministic chart kept this event" (positive) or skipped
(negative). Difficulty labels are the deterministic scores; future
human-edited charts can replace these labels without changing the record
format. Regenerate with:

```bash
cd LogicTests && swift run -c release -Xswiftc -enable-testing TrainingExport ../AI/Training/data 90
cd ../AI/Training && .venv/bin/python train.py   # needs .venv (coremltools 8 + sklearn 1.5)
```

**Developer diagnostics.** Diagnostics → song shows the AI section: backend,
model/schema versions, inference time, deterministic vs AI vs final
difficulty, per-event DSP → AI → fused importance with kept/skipped markers,
fallback counts, and an Export button that writes JSONL (features, predictions,
model version — never audio) to the app's Documents/AIExport folder. Chart
Debug gained an "AI" overlay: candidate events scaled by fused importance
(purple = AI used, gray = deterministic fallback).

## Automated reliability / stress testing

A dedicated stress suite (`*StressTests.swift`, ~48 tests) beats on every
subsystem deterministically on macOS via the `LogicTests` package:

- **Lifecycle** — 60 full cycles of load → analyze (fixture) → generate →
  validate → play-perfect → pause → restart → finish → save result → stats,
  with per-iteration tempo/seed variation; NaN/inf/lane/range invariants on
  every note; 100× restart judgment-leak checks; A→B→C→A×3 chart round-trips
  for every difficulty.
- **Concurrency** — an actor pipeline guarded by generation counters: racing
  analysis/chart completions landing out of order, stale generations rejected,
  50-generation switch storms, 40 racing completions of one generation.
- **Persistence** — 150 chart save/load cycles, corrupt chart files at every
  difficulty, missing charts, deleted-artifact recovery, version mismatches,
  100 result round-trips, corrupt results/queue/stats/playlists files (each
  loader refuses garbage and managers start empty), 50-replay churn with
  purge.
- **Queue** — 1,000-entry queue advanced 250×, duplicate entries, 500 rapid
  reorders (drag path), removing the current song, clear during playback,
  shuffle-during-playback membership, Repeat One / Repeat All / skip, and a
  500-entry persistence round-trip.
- **Input** — 200 rapid same-lane taps (each consumes a distinct note), 100
  alternating-lane taps (no cross-talk), multi-touch chords judging
  independently, duplicate-judgment prevention after a chord, near-boundary
  lane mapping, cancelled touches leaving no state, 500 pause/restart-during-
  hold rounds, hold completion vs early release.
- **AI** — 50× missing-model inference (nil, never throws), unloadable model
  URLs, invalid feature counts, NaN/±inf features, fusion fallback ×1,000,
  out-of-range AI score clamping, 30× advisor calls returning graceful
  fallback outcomes (deterministic score intact, `usedAI=false`), disabled-
  config short-circuit, catalog version sanity.
- **Haptics** — 200× pattern generation across every profile/category with
  stable gating, 10,000 profile lookups, 20,000-fire cooldown churn with
  exact admission math, engine-reset cooldown semantics, reduced/strength-
  scale paths.

Every stress test is hermetic (`AppDirectories.testRootOverride` + custom
replay dir), deterministic (fixed seeds/fixtures), and asserts invariants the
real game depends on — a failing stress test means a real stability bug, not
an environment flake.

## Chart + pipeline resilience ("Candidate 3" is gone)

Chart generation must never fail a song that has accessible audio. The old
outcome for pathological material (double-beat grids, extreme onset density,
unusual tempos — e.g. SICKO MODE's stop-start rhythm) was `Couldn't generate a
playable chart: unplayable pattern (candidate 3)`: all three seeded candidate
arrangements failed hard validation even after repair, and repair itself had
two holes.

- **Repair hardening** (`ChartValidator`). Repair now (a) drops malformed
  notes (NaN/negative time/duration, out-of-range lane) instead of leaving
  them to doom the whole candidate; (b) enforces the notes-per-second cap by
  thinning the densest 1 s window (then one final spacing pass, because
  thinning creates new neighbors); and (c) fixes a real bug in
  `keptGroupLanes`, whose one-sided filter (`time - first < 0.1`) silently
  accumulated **every earlier kept lane** — `prevGroupLanes` grew without
  bound, so the lane-jump checks became vacuous and 1↔4 bounces at 150 ms
  could survive repair.
- **Graceful fallback tiers** (`ChartGenerator`). Candidate rejection is now
  an internal outcome, never a user-facing error. Tier 1 runs the three
  seeded candidates; if all fail, tier 2 retries under relaxed spacing/jump
  constraints; tier 3 forces the legacy per-cell selection (works over the
  synthetic tempo grid); tier 4 is a minimal deterministic quarter-note chart
  on the detected beats. Every chart records its tier (`Chart.fallbackTier`),
  surfaced in the debug overlay and diagnostics.
- **User-facing error hygiene.** `ChartGenerationError` no longer leaks
  internal names — the message is "Couldn't generate a playable chart for this
  song…" with the technical reason kept for the debug log only. The analyzer's
  error surface was already cause-specific (protected / no track / reader /
  sample-read / format…).
- **Beat-grid hardening.** `BeatTracker` merges beats closer than an absolute
  0.09 s floor (double-beat artifacts), and `PhraseSequencer` refuses
  degenerate 4-beat groups whose sixteenth slots would sit below the
  validator's minimum spacing (~333 BPM+), letting those songs fall through to
  the legacy/synthetic tiers instead of producing unrepairable charts.
- **Interrupted-pipeline recovery** (`AppState`). If the app is killed or
  crashes mid-analysis, records used to stay stuck in "Analyzing…" forever
  (the only way out was deleting the song). On launch, any record in
  `.analyzing` / `.generatingChart` now automatically re-runs its pipeline
  (generation-gated, idempotent).
- **Audio session activation is off the main thread** (`AudioPlayer`). The
  synchronous `AVAudioSession.setActive` on the main actor is a documented
  system "Hang Risk" (logged as a fault); activation now runs on a detached
  task with a cancellable deferred start, so pause/stop during the startup
  window can't produce a phantom playback.
- **MPMediaQuery is off the main thread** (`MediaLibraryService`). On large
  libraries `MPMediaQuery.songs()` takes hundreds of ms to seconds; the whole
  refresh now queries on a background queue and only publishes the snapshot
  on the main actor.
- **Live debug overlay.** The gameplay timing overlay now also shows state +
  session id, playfield width / lane width / active-note count / generation
  tier, and the last raw touch (lane, normalized x/y, audio time, judged note
  id + Δ) — the exact data needed to see a tap that "should have hit" but
  didn't.

Test coverage: `ChartResilienceTests` (degenerate double-beat grids generate
valid charts on every difficulty, extreme onset density stays inside the NPS
cap, malformed-note repair, density-cap repair, beat-floor merging,
determinism under pathological input, user-facing message hygiene) plus the
existing ~48-test stress suite.

## Accessibility

The app is built to stay playable and understandable with assistive
technologies, without sacrificing the four-lane gameplay layout.

- **VoiceOver.** The playfield canvas is marked decorative; each lane is its
  own labeled element ("Lane 1, leftmost column" … "Lane 4, rightmost
  column") with the hint that the whole column is the touch target. A hidden
  live status element (`.updatesFrequently`) reports the current score and
  combo at any moment. The engine posts **announcements for misses, hold
  completions, combo milestones (10, 25, then every 50) and pause** through a
  throttled (0.6 s) handler that only fires while VoiceOver is actually
  running — never a constant stream. Judgment feedback, difficulty badges and
  status badges all carry text, so the game never relies on color alone
  (lane numbers are drawn on the playfield too).
- **Dynamic Type.** System text on every non-gameplay screen scales normally.
  Gameplay is fixed-layout by design (four full-width lanes), so it clamps
  Dynamic Type to `.accessibility2` — text grows, but the playfield never
  breaks. Artwork views are marked decorative so screen readers read the
  title/artist text instead of "image".
- **Reduce Motion.** With the system preference on, the background becomes
  essentially static: no particles, no hero breathing, no beat bloom, no blur
  scaling (colors still evolve gradually with sections). The combo pop
  becomes a static highlight instead of a scale animation, and the
  calibration cue flashes instantly instead of animating (the flash itself
  stays — it is the timing signal).
- **Reduced haptics.** The existing Settings toggle is honored, and when
  Reduce Motion is on the engine automatically uses softer hits with no miss
  feedback unless the user has an explicit haptics preference.
- **Labels & hints.** Every icon-only control carries a label: queue
  shuffle/repeat/clear, settings sliders (label + live value), chart-editor
  undo/redo/delete/scroll, replay transport, preview scrubbing, playlist
  add/rename/delete. Results combine score/accuracy/combo into one clean
  readout, and calibration announces its start and finish.
- **Contrast.** Gameplay HUD text sits on a readability scrim; judgment
  popups have thick dark outlines; lane tiles are bright identity colors on a
  dark field; results/statistics use solid high-contrast surfaces.

## Known limitations (honest)

- **Core Haptics requires a physical iPhone.** The simulator can't vibrate; the
  app degrades gracefully and says so in Diagnostics.
- **Gameplay presentation.** The game screen is full-bleed: edge-to-edge lanes,
  large glowing tiles, a visible hit-zone line, prominent score/combo and a
  song-artwork background (blurred artwork + extracted colors + vignette +
  subtle beat pulse). Judgments pop big and fade fast; visuals never gate
  timing.
- **Music-library audio depends on Apple's access model.** iOS exposes raw
  audio (`assetURL`) only for items the app can reach. Downloaded Apple Music
  items expose an asset URL; DRM-protected items and undownloaded cloud items
  don't, and the app doesn't try to bypass that. They still appear in My Music
  with a cause-specific label (DRM Protected / Not Downloaded / Audio
  Unavailable).
- **Gameplay sound effects** (settings toggle present) arrive in a later
  milestone; the app plays the song itself, with no extra SFX yet.
- **Event classification** (kick-like/snare-like/…) is a spectral-shape
  heuristic, not instrument identification.
- **AI is self-supervised so far.** Version 1's models are trained to
  reproduce the deterministic system's own decisions (the only ground truth
  available before human-authored charts exist). The architecture is built for
  human labels to replace synthetic ones later; until then the AI refines the
  deterministic pipeline (difficulty fusion, event re-ranking) and stays
  safely behind it.
- **Simulator-verified, hardware still pending.** The gameplay loop was
  exercised end-to-end in the iPhone 17 Pro and iPhone 17e simulators via
  `-demoAutoplay`: songs are analyzed, charted and auto-played (Perfect runs,
  holds completed, all four lanes used), and screenshots were pixel-verified
  for four distinct full-width columns with gameplay content reaching the
  screen edges (no clipped outer lanes) on two device sizes. Kill-and-relaunch
  mid-run recovers the interrupted pipeline into live gameplay instead of a
  permanently stuck "Analyzing" state. Physical-device validation (touch
  latency, real haptics, audio latency, Music-library behavior) is still
  outstanding.
- Section labels (intro/verse/chorus/…) are energy-based heuristics.

## Milestone status

Task 1 of the development roadmap is complete: the on-device AI difficulty
system (real Core ML models with deterministic fusion + fallback + diagnostics)
plus simulator autoplay and deterministic gameplay simulation. The fullscreen
gameplay correction is also complete: four-lane colored presentation, giant
tiles, hold notes (generation, validation, gameplay, scoring) and the Debug
demo-song/`-demoAutoplay` path. The rest of the roadmap (chart preview polish,
multiple per-song difficulties, practice mode, queue, playlists, statistics,
chart editor, haptic profiles, backgrounds, UI polish, …) proceeds in order
from here; the AI architecture already isolates section classification /
pattern selection / lane assignment as future model ports without touching the
deterministic core.