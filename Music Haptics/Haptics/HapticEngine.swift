import CoreHaptics
import Foundation

/// Thin, safe wrapper around CHHapticEngine.
/// All haptics are triggered relative to the audio clock (hit times), and the
/// engine is torn down on pause/seek so stale scheduled patterns never play.
/// Playback is strictly best-effort: nothing here can block gameplay.
@MainActor
final class HapticEngine {
    // Workaround for swiftlang/swift#87316 (see StatsManager).
    deinit {}
    private var engine: CHHapticEngine?
    private(set) var isSupported: Bool

    /// Minimum gap between fires (ms) — the global anti-stack guard from the
    /// active profile. 0 = unlimited.
    var cooldownMs: Double = 0 {
        didSet { cooldown = HapticCooldown(minIntervalMs: cooldownMs) }
    }
    private var cooldown = HapticCooldown(minIntervalMs: 0)

    init() {
        isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func prepare() {
        guard isSupported else { return }
        if engine == nil {
            do {
                let newEngine = try CHHapticEngine()
                newEngine.resetHandler = { [weak self] in
                    Task { @MainActor in self?.handleStopped() }
                }
                newEngine.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in self?.handleStopped() }
                }
                engine = newEngine
            } catch {
                isSupported = false   // e.g. simulator — degrade gracefully
            }
        }
        if let engine { try? engine.start() }   // haptics are best-effort
    }

    func play(_ pattern: CHHapticPattern, atDelay delay: Double = 0) {
        guard isSupported, let engine else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard cooldown.allowFire(at: now) else { return }
        do {
            let player = try engine.makePlayer(with: pattern)
            // Patterns can be scheduled at an exact offset from now (used for
            // beat-aligned rhythm haptics); negative delays fire immediately.
            try player.start(atTime: CHHapticTimeImmediate + max(0, delay))
        } catch {
            // Haptics are best-effort; gameplay never depends on them.
        }
    }

    /// Cancels anything scheduled and tears the engine down.
    /// Call `prepare()` again before the next use.
    func stopAll() {
        if let engine { engine.stop() }
        engine = nil
        cooldown.reset()
        cooldownMs = 0
    }

    private func handleStopped() {
        engine = nil
    }
}