import AVFAudio
import Combine
import Foundation
import os

/// Real audio playback with an authoritative, monotonic clock.
///
/// The gameplay clock is derived from `AVAudioPlayer.deviceCurrentTime`
/// (the audio hardware clock), NOT from `Date()`. This keeps notes synced to
/// what the user actually hears, including through pauses and seeks.
@MainActor
class AudioPlayer: ObservableObject {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    enum PlaybackState: Equatable {
        case idle, loading, playing, paused, failed
    }

    @Published private(set) var state: PlaybackState = .idle

    private var player: AVAudioPlayer?
    private var startAudioTime: Double = 0   // audio (content) time when playback started
    private var startDeviceTime: Double = 0  // device clock at that moment
    private var rateValue: Double = 1.0      // practice speed; 1.0 = normal
    private var observers: [NSObjectProtocol] = []
    /// True once this process has configured the audio session. Session
    /// activation is deliberately NOT on the play() critical path: the sync
    /// `setActive` on the main thread is an AVAudioSession "Hang Risk"
    /// (system-logged fault), so it runs once, off-main, at load() time.
    nonisolated private static let sessionReady = OSAllocatedUnfairLock(initialState: false)

    var duration: Double { player?.duration ?? 0 }

    /// Current position on the audio timeline. This is the gameplay clock.
    /// While playing it advances at `rate` × real time, so at 0.5× the whole
    /// game — audio, notes, judgments — moves together (practice speed).
    var currentTime: Double {
        guard let player else { return 0 }
        if state == .playing {
            return PracticeClock.contentTime(anchorContent: startAudioTime,
                                             anchorDevice: startDeviceTime,
                                             nowDevice: player.deviceCurrentTime,
                                             rate: rateValue)
        }
        return player.currentTime
    }

    var rate: Double { rateValue }

    /// Changes the playback rate mid-flight. The clock is re-anchored at the
    /// current content position so `currentTime` stays continuous across the
    /// change (and pause/resume re-anchors again), exactly like a seek.
    func setRate(_ rate: Double) {
        guard let player else { return }
        let clamped = min(max(rate, 0.5), 2.0)
        if state == .playing {
            startAudioTime = player.currentTime
            startDeviceTime = player.deviceCurrentTime
        }
        player.rate = Float(clamped)
        rateValue = clamped
    }

    var volume: Float {
        get { player?.volume ?? 1 }
        set { player?.volume = newValue }
    }

    // Observer removal happens in `stop()` (main-actor, idempotent). The
    // deinit can't touch the array under Swift 6 strict concurrency, and the
    // observer closures are [weak self], so an un-stopped player only leaves
    // inert observer entries behind, never a retain cycle.

    func load(url: URL) throws {
        state = .loading
        do {
            let loaded = try AVAudioPlayer(contentsOf: url)
            // Required for practice speed (0.5×–1.0×); must be set before play.
            loaded.enableRate = true
            loaded.rate = Float(rateValue)
            loaded.prepareToPlay()
            player = loaded
            state = .idle
            setupObservers()
            ensureSessionConfigured()
        } catch {
            player = nil
            state = .failed
            throw error
        }
    }

    /// Synchronous start. Playback is a plain `AVAudioPlayer` call that never
    /// blocks; session activation (the only audio-stack call that can hang)
    /// was kicked off at load() on a background thread, so by the time play()
    /// runs the session is already configured on every realistic path.
    func play(from time: Double = 0) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        player.play()
        startAudioTime = player.currentTime
        startDeviceTime = player.deviceCurrentTime
        state = .playing
    }

    func pause() {
        guard state == .playing, let player else { return }
        player.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, let player else { return }
        player.play()
        // The device clock keeps running while paused, so re-anchor the clock.
        startAudioTime = player.currentTime
        startDeviceTime = player.deviceCurrentTime
        state = .playing
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        if state == .playing {
            startAudioTime = player.currentTime
            startDeviceTime = player.deviceCurrentTime
        }
    }

    /// Idempotent: safe to call repeatedly and from any state. Leaves the
    /// player unloaded (idle) so a subsequent `load` starts clean.
    func stop() {
        player?.stop()
        player = nil
        state = .idle
        #if os(iOS)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        #endif
    }

    // MARK: - Audio session (iOS only — macOS has no AVAudioSession)

    #if os(iOS)
    /// Configures the audio session once per process. Called from `load()`,
    /// which runs well before `play()` on every realistic path, so playback
    /// itself never has to wait on (or block) the audio stack.
    private func ensureSessionConfigured() {
        let ready = Self.sessionReady.withLock { $0 }
        guard !ready else { return }
        Task.detached(priority: .userInitiated) { Self.activateSessionSync() }
    }

    /// Runs the (synchronous) session activation OFF the main thread. The
    /// sync `setActive` on the main actor is a documented AVAudioSession
    /// "Hang Risk" (system-logged fault); the audio stack can block on it.
    /// Nonisolated static + no captures keeps it Sendable-clean. The lock is
    /// only flipped on success so a failed activation is retried next load.
    nonisolated private static func activateSessionSync() {
        let already = Self.sessionReady.withLock { $0 }
        guard !already else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            Self.sessionReady.withLock { $0 = true }
        } catch {
            // Playback can still proceed without an active session on most devices.
        }
    }

    // MARK: - System events (interruptions, route changes, media reset)

    private func setupObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in self?.handleInterruption(rawType: raw) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in self?.handleRouteChange(rawReason: raw) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(rawType: UInt?) {
        guard let raw = rawType, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began { pause() }
        // On .ended we intentionally do NOT auto-resume; the game resumes safely
        // via explicit user action so state never gets out of sync.
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard let raw = rawReason, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones unplugged / route vanished: pause rather than keep playing
        // through an unexpected output.
        if reason == .oldDeviceUnavailable { pause() }
    }

    private func handleMediaServicesReset() {
        player = nil
        state = .idle
    }
    #else
    private func ensureSessionConfigured() {}
    private func setupObservers() {}
    #endif
}