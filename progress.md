# Haptic Tiles / Music Haptics — Project Progress

**App:** Haptic Piano (bundle `com.eshannandakumarpersonalteam.MusicHaptics`)
**Current version:** 1.1 (11) · **539 automated tests, all passing**
**Last updated:** September 12, 2026

---

## 1. What the project started as

The repo began as a partially developed prototype — a single-template Xcode project
for a four-lane music/rhythm game ("Magic Tiles"-style) with Core Haptics
integration. In its earliest state:

- The project would not open in Xcode 16 at all: *"…cannot be opened because it is
  in a future Xcode project file format."*
- No working app icon set, no valid accent color in the asset catalog.
- A rough four-lane playfield with unreliable touch handling (touches only
  registered in a thin strip near the top of the screen).
- A prototype AI training folder (`AI/Training/train.py`) and a mirrored macOS
  Swift package (`LogicTests/`) used to compute chart statistics.

The first passes of work (chronologically):

1. **Xcode 16 / iOS 18 SDK migration** — project format rebuilt, schemes/test plan
   repaired, asset catalog fixed so the app builds and installs.
2. **Project preservation pass** — understood and kept the existing gameplay logic
   (analysis → chart generation → gameplay → scoring) rather than rewriting it.
3. **Feature expansion** — music library import, per-song analysis, chart
   generation, practice mode, queue playback, replays, statistics.
4. **Alpha 1 productization** — onboarding, settings (visuals, haptics profiles,
   calibration, note speed), accessibility (VoiceOver lanes, Reduce Motion,
   Dynamic Type bounds), app icons (light/dark/tinted), tester-ready build
   pipeline (`xcodebuild archive` → signed IPA → `devicectl` install).

---

## 2. What the app is now

A complete, testable four-lane rhythm game that plays YOUR music:

- **Import** any audio file (Files app) or pick from Apple Music library items
  the app can access; songs, analysis and charts persist locally (SwiftData +
  JSON on disk). No servers, no accounts, no network calls.
- **Analysis pipeline** (`Analysis/`): onset detection, beat tracking, tempo
  estimation, section segmentation (intro/verse/chorus/bridge/breakdown/outro).
- **Chart generation** (`Chart/`): Magic Tiles 3-style musical charts — beat-grid
  quantization, phrase templates (rhythms composed per 4-beat phrase, repeated
  musical phrases reuse their template), lane motifs (walks/alternations with
  lane-balance pressure so all four lanes stay used), a gated hold-note pass,
  a playability validator with repair, and a quality scorer that picks the best
  of three seeded candidates. Four fallback tiers guarantee every playable song
  gets a playable chart. Charts are versioned (currently v5); cached charts
  regenerate automatically when the version changes.
- **Gameplay engine** (`Game/`): audio-clock-driven (AVAudioPlayer device-time
  anchored, never wall-clock drift), 60 Hz main-loop tick with generation guards
  (exactly one live loop per session), spatial tile catching (tapping the tile
  you SEE works anywhere in the lane), timing-window judgment (Perfect/Great/
  Good/Miss with user calibration), combo/multiplier scoring, hold notes,
  Core Haptics profiles (musical/beat-focused/strong/minimal), and an optional
  per-moment dynamic tile speed (±12% around the user's Note Speed, driven by
  the locally detected tempo — one shared curve for rendering AND hit detection,
  so what you see is exactly what you hit).
- **App shell** (`App/`): `AppState` owns a single preparation boundary —
  analysis/chart generation runs as cancellable, token-guarded pipelines with a
  durable `PipelineStatus` surface (queued → analyzing → charting → ready /
  failed), non-blocking demo generation, and one "prepare session" path used by
  Home, Song Detail, Playlists and the Queue. No more transient spinners that
  silently bounce back.
- **UI system** (`UI/`): Library home (My Music / Statistics / Playlists rows,
  quick-play, demo groove), Song Detail (difficulty picker, chart preview,
  practice setup, audio probe), Game (full-bleed playfield + safe-area HUD),
  Results (milestones, replay, run analytics), Settings, Calibration, Replay
  viewer. Artwork-derived background themes (palette extraction, blur, energy
  variants) built OFF the main thread and cached per artwork.
- **Accessibility**: VoiceOver lane buttons with position-based labels, live
  score/combo announcements (throttled), Reduce Motion honored everywhere,
  reduced haptics, bounded Dynamic Type in gameplay.
- **Quality gates**: 539 XCTests covering pure math (geometry, timing curves,
  tempo models), the full input pipeline (stress: rapid taps, chords, cancels,
  pause-during-hold), chart generation determinism/lane balance/sync, the
  analysis pipeline, persistence, and the app shell's cancellation semantics.

---

## 3. Architecture map

```
Music Haptics/
├── App/            HapticPianoApp (entry), AppState (preparation boundary,
│                   queue, results), PipelineStatus (durable op state)
├── Analysis/       AudioAnalyzer, OnsetDetector, BeatTracker (DSP)
├── Audio/          AudioPlayer (device-time anchor), AudioMetadata, AudioSource
├── AI/             AIFeatures, AISystem, AIInference (optional advisor port)
├── Chart/          ChartGenerator (4 tiers), ChartPatterns (phrase templates),
│                   PatternGenerator (lane motifs), HoldGenerator, ChartValidator,
│                   ChartQualityScorer, ChartDifficultyAnalyzer, ChartEditor
├── Dev/            DemoSongFactory (synthesized 28 s groove, generated off-main)
├── Game/           GameEngine (loop, input, holds, scoring glue), GameState,
│                   NoteScheduler, HoldTracker, ScoreManager, InputJudge,
│                   PlayfieldMath (PlayfieldGeometry · SpatialCatch ·
│                   NoteMovement · HitTileTiming · MissTileTiming),
│                   HapticEngine/HapticScheduler/HapticPatterns
├── Models/         Chart, SongRecord, AudioAnalysis, Beat, … (SwiftData + Codable)
├── Persistence/    ChartStorage (versioned), AnalysisStorage, ResultsStore
├── Queue/          QueueManager (advance decisions, Repeat One, skip)
├── UI/             Library, MyMusic, Playlists, SongDetail, Game, Results,
│                   Settings, Calibration, Replay, Onboarding, ChartPreview,
│                   ChartEditor + Components/ (GamePlayfieldView, LaneTouchLayer)
├── Utilities/      Sandbox dirs (crash-safe fallbacks), SplitMix64, Format
└── Visuals/        ArtworkPalette (pure, unit-tested theme analysis)
```

Key contracts that keep the game coherent (all pinned by tests):

- **One geometry.** `PlayfieldGeometry` (hit line 0.875, spawn 0.03, tile height
  0.115 of the playfield height) is shared verbatim by the Canvas renderer, the
  UIKit touch layer, and the engine's spatial matcher. `SpatialCatch.distance`
  projects a touch onto the SAME curve the renderer draws — including the full
  head→tail span for holds.
- **One clock.** All judgment and rendering math is `(chartTime − audioTime) / lead`
  on the audio clock; effects run on fixed pure-math timers independent of frame
  rate or travel speed.
- **One preparation boundary.** Every "play this" action funnels through
  `AppState`'s single session-builder with token-gated cancellation; views render
  `PipelineStatus` instead of inventing their own loading flags.

---

## 4. The bug-fix pass in this commit (September 12, 2026)

Symptoms reported on-device after the v2 shell redesign: screen appeared split
in two with only two tiles on the left, heavy stutter, occasional screen flash,
the score number clipped by the Dynamic Island, and holds completing instantly
instead of tracking how long the finger stayed down (with the tail ring drawn
outside the tile).

Root causes found and fixed (with regression tests):

1. **Split screen / two lanes** — the gameplay view nested a `GeometryReader`
   inside a ZStack that was later `.ignoresSafeArea`-expanded. The Canvas was
   measured pre-expansion and could receive a half-width proposal on notched
   devices, so lanes were computed at half width (2 lanes on the left half).
   Rebuilt the body around ONE root `GeometryReader` that owns the full
   (already-expanded) display: background, renderer, touch layer, HUD scrim and
   controls all get the same measured size; overlays (pause/results/debug) moved
   to a `.overlay` so they keep the same bounds. The HUD VStack is inset by the
   real safe-area insets while the playfield stays edge-to-edge.
2. **Score clipped by the Dynamic Island** — fixed by the same restructure (HUD
   now sits inside explicit safe-area padding, not under the island) plus a
   width-safe score text (`lineLimit(1)` + `minimumScaleFactor` + min width)
   so large scores can never overflow the box.
3. **Stutter** — three contributing causes fixed:
   - The background view re-diffed on every 60 Hz `currentTime` publish because
     it received raw fractional `pulse`/`energy` values. Both are now quantized
     to ⅛ steps before the view, and the hero layer uses the quantized energy —
     SwiftUI only re-renders the artwork layers when values actually change.
   - `dynamicLead(at:)` (tempo-curve lookup with a binary search + median scan)
     ran per visible tile per frame; now cached on a 20 ms frame-step so one
     computation serves the whole frame (renderer, spawn window, input).
   - The playfield Canvas gets `.drawingGroup()` so the tile layer renders on
     the GPU with a stable frame cadence.
4. **Screen flash** — the beat-pulse background bloom jumped to 1.0 in a single
   frame on strong beats. The pulse now rises with a capped step (≤ 0.55 on
   strong beats, ≤ 0.22 otherwise) and decays smoothly; visually a glow, not a
   flash. (Reduce Motion / effects-off still disable it entirely.)
5. **Holds completing instantly** — two real bugs:
   - Progress was computed from the note's HEAD timestamp. A spatial body press
     (the Magic Tiles 3 catch, added earlier) starts the hold before the head
     arrives on the audio clock, so the fill began pre-advanced and short holds
     could complete on arrival. The hold now anchors at the actual press time
     (autoplay still anchors at the head) and fills from 0 → 100% at the tail.
   - The 60 Hz tick completed holds at `endTime − 0.02`, contradicting the
     tracker's release grace and making near-tail releases complete silently.
     Completion now happens at the tail, in step with `release`.
6. **Hold completion is proportional** — `HoldTracker.release` now returns a
   `ReleaseResult` carrying the MEASURED sustain fraction (computed before the
   active entry is removed — the engine previously queried it after removal and
   always got zero). The partial bonus (`bankPartialHold`) uses that fraction,
   the renderer shows the honest fill for a short moment on early release, and
   `progressByNote` records the final value for tests/diagnostics.
7. **Tail ring outside the tile** — the ring was stroked at the tile's max-Y
   with an unclamped radius, poking below the tile onto the lane. Ring drawing
   is now a dedicated `drawClampedTailRing` that clamps the center inside the
   body; the active-hold fill is clipped to the rounded body so the lane-color
   gradient can never leak either. While sustaining, the fill grows from the
   head upward with the release ring riding the fill boundary — all inside the
   tile.
8. **Touch drift** — the raw touch layer used to re-map lanes whenever a finger
   crossed a divider, firing accidental lane-up/lane-down mid-hold. Fingers now
   stay attached to the lane where they started (normal hold drift sustains the
   hold); leaving the playfield still cancels.

**Tests:** new `HoldDurationTests` (7 tests) pin the press-time anchor, the
measured release fraction, proportional banking, tail-gated completion, and the
recorded progress surface. All prior suites still pass: **539/539**.

---

## 5. Version / build history

| Version | Build | Milestone |
|---|---|---|
| 1.0 | 1–4 | Alpha 1 tester builds (Xcode 16 migration, icons, onboarding) |
| 1.1 | 5–8 | Feature expansion, settings hardening, HUD fix |
| 1.1 | 9–10 | Bug-fix audit (settings slider ranges, AI hardening, regression tests) |
| 1.1 | 11 | Magic Tiles 3 sync (onset-first charting v5), dynamic speed, touch/hold fixes |
| 1.1 | 11 | This pass: geometry restructure, stutter/flash fixes, proportional holds |

Deliverable pipeline: `xcodebuild archive` → signed IPA on the Desktop
(`Haptic Piano …ipa`) → `devicectl device install app` to a connected iPhone.

## 6. Known-good baselines

- `git` history: `ba53753` initial template → `9150f99` Alpha 1 full
  implementation (294 files) → this commit (bug-fix pass).
- `LogicTests/` mirrors app sources as symlinks for the standalone macOS
  `ChartStats` tool; changes to shared sources propagate automatically.
- `.gitignore` covers `LogicTests/.build/` (865 MB of SwiftPM artifacts),
  `.freebuff/`, `.DS_Store`, and AI training venv/data/output.

## 7. What's next (candidates, not commitments)

- Commit + tag the current state; set up a remote backup.
- On-device Instruments pass (Time Profiler + Core Animation FPS) to verify the
  stutter fixes on iPhone 17 hardware, not just in tests.
- Chart editor polish (the `ChartEditor` core exists; the UI is minimal).
- Optional Game Center / local leaderboards; replay sharing between testers.
