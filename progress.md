# Haptic Tiles / Music Haptics — Project Progress

**App:** Haptic Piano (bundle `com.eshannandakumarpersonalteam.MusicHaptics`)
**Current version:** 1.1 (14) · **599 automated tests, all passing**
**Last updated:** September 14, 2026

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
  gets a playable chart. Charts are versioned (currently v6); cached charts
  regenerate automatically when the version changes.
- **Gameplay engine** (`Game/`): audio-clock-driven (AVAudioPlayer device-time
  anchored, never wall-clock drift), 60 Hz main-loop tick with generation guards
  (exactly one live loop per session), a display-synchronized Canvas timeline,
  absolute-time integrated tile projection, spatial tile catching (tapping the
  tile you SEE works anywhere in the lane), timing-window judgment (Perfect/Great/
  Good/Miss with user calibration), combo/multiplier scoring, hold notes,
  Core Haptics profiles (musical/beat-focused/strong/minimal), and a deterministic
  Standard Math + optional Foundation Models intelligence layer. Dynamic Speed is
  a precomputed, section-aware visual curve (with difficulty scaling) shared by
  rendering and spatial catch; scoring timestamps and hit windows never change.
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
  variants) built OFF the main thread and cached per artwork. Gameplay rendering
  now has one full-screen geometry owner, one four-lane touch surface, a
  display-synchronized Canvas, and no production debug/autoplay control cluster.
- **Accessibility**: VoiceOver lane buttons with position-based labels, live
  score/combo announcements (throttled), Reduce Motion honored everywhere,
  reduced haptics, bounded Dynamic Type in gameplay, and reduced visual speed
  variation without changing the authoritative gameplay timeline.
- **Quality gates**: 599 XCTests covering pure math (geometry, timing curves,
  tempo models, absolute projections), the full input pipeline (stress: rapid
  taps, chords, cancels, pause-during-hold), hold synchronization and measured
  partial progress, chart generation determinism/lane balance/sync, the
  analysis pipeline, persistence, AI availability/fallback/validation, and the
  app shell's cancellation semantics.

---

## 3. Architecture map

```
Music Haptics/
├── App/            HapticPianoApp (entry), AppState (preparation boundary,
│                   queue, results), PipelineStatus (durable op state)
├── Analysis/       AudioAnalyzer, TempoAnalysis (capability-gated tempo tiers),
│                   OnsetDetector, BeatTracker (DSP)
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

## 5. Enhanced intelligence, hold synchronization, and rendering pass

This pass preserves the authoritative audio-time engine and adds an optional
analysis tier above it. It does not let AI, Dynamic Speed, backgrounds, haptics,
or UI state mutate scoring timestamps, hit windows, audio time, input state, or
judgment classification.

### Two-tier gameplay intelligence

- **Every device — Standard Math Engine:** `StandardMathIntensityAnalyzer` builds
  a deterministic, bounded curve from chart density, simultaneous notes/chords,
  section energy, and semantic section labels. It uses two-pass smoothing and
  broad four-second buckets, so isolated notes cannot make speed oscillate.
- **Foundation Models-capable devices — Enhanced On-Device AI:**
  `OnDeviceAIService` refreshes `SystemLanguageModel.default.availability` on
  iOS 26 and only enters the enhanced path for the OS-reported `.available`
  state. It sends a compact, bounded `GameplayAIContext` containing note timing
  summaries, intervals, density spikes, chords, holds, lane travel, section
  energy, and the prepared Standard Math speed curve to Apple's local model.
  The model returns structured speed-intensity points, chart-quality findings,
  and optional difficulty/hold/chord recommendations. It never receives raw
  audio, user identity, or network data.
- **Deterministic boundary:** all model points are sorted, clamped to the song
  duration and normalized range, deduplicated, bounded to 24 points, and must
  contain a usable curve before acceptance. Findings are bounded to 24 entries
  with bounded text/severity/section indices. Cached plans are rejected when
  song ID, chart version, note count, duration, schema, model version, or
  intensity no longer match. Invalid, missing, unavailable, or timed-out output
  falls back to Standard Math without delaying gameplay.
- **Actual product effect:** an accepted plan changes only the pre-game visual
  Dynamic Speed curve. Recommendations and findings are advisory and stored for
  diagnostics/product surfaces; they do not silently apply difficulty, rewrite
  chart events, alter score, or make accuracy look better. Player history
  analysis runs only after results/settings while idle and is cancelled before
  the next session.

### Intelligent Tempo Analysis (September 14, 2026)

- Added a capability-gated tempo boundary (`TempoAnalyzer`) above the existing
  `TempoEstimator`. Every device retains the Standard DSP/math path; the new
  path consumes only the compact spectral-flux envelope produced during
  preprocessing and never runs in the gameplay loop.
- The enhanced path is eligible only when iOS reports Foundation Models as
  available, Core ML is present, and the validated bundled `AITempo` model is
  present in the app bundle. Capability selection is based on live
  framework/model availability, not an iPhone marketing name. The model is
  compiled by Xcode into `AITempo.mlmodelc`; devices without Foundation Models
  availability still use the DSP path.
- Tempo results now carry BPM, confidence, stability, half/double-time
  ambiguity, tempo-change detection, analyzer/version, measured analysis and
  inference durations, fallback reason, and cache-hit state. Low-confidence,
  missing, invalid, or ambiguous enhanced output returns the stable DSP result.
- The deterministic cache fingerprints source URL, sample rate, duration,
  compact flux content, analyzer kind, and analyzer version. Version/model
  changes invalidate entries; cache and fallback state are visible in Debug
  diagnostics and the Settings toggle is disabled when the enhanced tier is
  unavailable.
- The bundled model was trained by `AI/Training/train_tempo.py` on 2,400
  deterministic synthetic songs with a held-out song-disjoint validation split
  (1.000 top-1 candidate accuracy vs 0.325 DSP baseline; MAE 0.05956, RMSE
  0.15387). The model is 42 KB at source and the built `AITempo.mlmodelc` was
  loaded and executed by the focused iOS 26 simulator regression test.
- One stable tempo result is handed to the existing beat tracker/chart/Dynamic
  Speed boundary. No frame-to-frame BPM updates, scoring changes, note-timestamp
  changes, network calls, audio uploads, or gameplay timing changes were added.
- A real `AITempo.mlmodel` is now committed with its deterministic training
  script and manifest metrics. The iOS 26 device build succeeded and contains
  `AITempo.mlmodelc`; installation was attempted on Eshan’s iPhone 17, but
  CoreDevice reported the phone unavailable at validation time, so no physical
  install is claimed for this model build.

### Confirmed hold and rendering fixes

- Hold head, body, tail, active fill, spatial catch, and release now use the same
  prepared `DynamicSpeedProfile` and absolute-time integrated projection. There
  is no second fixed-pixels-per-second hold animation. The tail remains tied to
  its chart end timestamp through slow → fast → slow regions.
- Hold progress is measured from the authoritative sustain timestamp, not frames,
  timer ticks, distance, or an animation duration. A real body press anchors the
  sustain at the actual press time; autoplay anchors at the chart head. Release
  computes its fraction before removing the active hold, so partial bonuses and
  the temporary visual state reflect the actual amount held.
- The Canvas uses `TimelineView(.animation)` for display cadence while the logic
  timer remains responsible for deterministic scoring/state. A stable per-run
  latency sample and monotonic wall/audio render anchor prevent route-latency or
  timer jitter from re-positioning existing notes backward. `drawingGroup()` and
  coarse HUD/background publications reduce main-thread SwiftUI churn.
- The playfield is owned by one root geometry contract and one four-lane input
  surface. The HUD uses real safe-area insets and a width-safe score block, so
  the Dynamic Island cannot clip the score or split the playfield. The former
  debug/autoplay control cluster is not present in the production HUD. The old
  top gray rectangular scrim was removed rather than covered; gameplay now has
  one lightweight score panel instead of an extra full-width compositing layer.
- Reduce Motion now disables section speed variation and softens sensory effects
  without changing scoring fairness. Dynamic Speed OFF produces a constant
  profile and skips dynamic calculations. Difficulty still changes stable speed,
  dynamic response, chart density, and chart-generation behavior through the
  existing difficulty model.

### Validation evidence

- Focused iOS Simulator 26.3.1 run on **iPhone 17 Pro**: **37 tests, 0
  failures** across `GameplayIntelligenceTests`, `DynamicSpeedTests`, and
  `HoldDurationTests`.
- Full iOS Simulator 26.3.1 run on **iPhone 17 Pro**: **601 tests, 0 failures**
  in the final validation run. Build/test output contained no compiler
  warning/error diagnostics. The only tool warning was Xcode's benign
  AppIntents metadata notice for the test target, which has no AppIntents
  dependency.
- The focused regression set covers model-output sanitization/fallback,
  availability-tier derivation, context capture for chords/holds/sections,
  absolute projection monotonicity/continuity/frame-cadence independence,
  slow → fast → slow hold endpoints, musical hold duration, difficulty ordering,
  Dynamic Speed OFF, intensity range, and unchanged note timestamps.
- The simulator exercised unavailable Foundation Models fallback behavior and
  the full deterministic path. Foundation Models `.available` inference was
  not observed in this simulator run; the bundled Core ML tempo artifact was
  nevertheless loaded and executed directly by the regression test. No model
  download or successful live Foundation Models response is claimed. The final
  iOS 26 device build succeeded with the model included, but installation was
  attempted while Eshan’s iPhone 17 was unavailable and therefore was not
  completed.

---

## 6. Version / build history

| Version | Build | Milestone |
|---|---|---|
| 1.0 | 1–4 | Alpha 1 tester builds (Xcode 16 migration, icons, onboarding) |
| 1.1 | 5–8 | Feature expansion, settings hardening, HUD fix |
| 1.1 | 9–10 | Bug-fix audit (settings slider ranges, AI hardening, regression tests) |
| 1.1 | 11 | Magic Tiles 3 sync (onset-first charting v5), dynamic speed, touch/hold fixes |
| 1.1 | 11 | Geometry/stutter/flash fix, safe-area HUD, proportional holds |
| 1.1 | 14 | Two-tier gameplay intelligence, bounded Foundation Models planning,
  integrated hold projection, production gameplay rendering cleanup, and
  capability-gated Intelligent Tempo Analysis |

Deliverable pipeline: `xcodebuild archive` → signed IPA on the Desktop
(`Haptic Piano …ipa`) → `devicectl device install app` to a connected iPhone.

## 7. Known-good baselines

- `git` history: `ba53753` initial template → `9150f99` Alpha 1 full
  implementation (294 files) → this commit (bug-fix pass).
- `LogicTests/` mirrors app sources as symlinks for the standalone macOS
  `ChartStats` tool; changes to shared sources propagate automatically.
- `.gitignore` covers `LogicTests/.build/` (865 MB of SwiftPM artifacts),
  `.freebuff/`, `.DS_Store`, and AI training venv/data/output.

## 8. What's next (candidates, not commitments)

- Commit + tag the current state; set up a remote backup.
- On-device Instruments pass (Time Profiler + Core Animation FPS) to verify the
  stutter fixes on iPhone 17 hardware, not just in tests.
- Chart editor polish (the `ChartEditor` core exists; the UI is minimal).
- Optional Game Center / local leaderboards; replay sharing between testers.
