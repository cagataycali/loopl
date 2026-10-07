import Foundation
import Loopl
#if canImport(MediaPlayer) && os(iOS)
import MediaPlayer
import AVFoundation
import UIKit
#endif

// `music` — the system music player (Apple Music, or whatever the system player holds) as one tool:
// play · pause · next · previous · volume · now_playing. Lane TOOLS-EXPAND, 2026-10-06, owner: "so I can change the
// volume, next song, pause playing". ON by default (asked for explicitly). No approval card: every action is low risk
// and reversible from the Lock Screen. One tool with an `action` enum on purpose — unlike the clipboard, where
// "copy" fooled a 0.8B into writing, the music verbs are the words people say (measured, `MusicToolMeasurement`).
//
// iOS limitation, documented here and in Settings: there is NO public API that sets the system volume. The only
// supported route is the slider inside `MPVolumeView`; loopl moves that slider off-screen, iOS shows its own
// volume HUD, and the result reports the level the slider ended at. `AVAudioSession.outputVolume` is read-only.
// `now_playing` reads `nowPlayingItem`, which needs the Media Library permission (`NSAppleMusicUsageDescription`,
// asked just in time and only for that action); play/pause/skip need no permission at all.
//
// `MusicSource` is the seam: `SystemMusicSource` on an iPhone, `FixtureMusicSource` for tests, the real-model
// harness and `--design-fixture music`. The Simulator has no Music app, so the tool says so there.

/// What the player reports after an action.
public struct NowPlaying: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Codable { case playing, paused, stopped }
    public var state: State
    public var title: String?
    public var artist: String?
    public var album: String?
    /// 0–100, `nil` when unknown.
    public var volume: Int?
    public init(state: State, title: String? = nil, artist: String? = nil, album: String? = nil, volume: Int? = nil) {
        self.state = state; self.title = title; self.artist = artist; self.album = album; self.volume = volume
    }
}

public protocol MusicSource: Sendable {
    func play() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    /// 0–100. Throws when the device cannot set the volume (documented iOS limitation).
    func setVolume(_ percent: Int) async throws
    /// Current state (and title/artist when the user allowed the library).
    func nowPlaying() async throws -> NowPlaying
}

/// Deterministic player for tests and the harness: a tiny queue, a volume, a log of what was asked.
public final class FixtureMusicSource: MusicSource, @unchecked Sendable {
    public struct Track: Sendable, Hashable { public var title: String; public var artist: String; public var album: String
        public init(title: String, artist: String, album: String) { self.title = title; self.artist = artist; self.album = album } }
    public var queue: [Track]
    public var index = 0
    public var state: NowPlaying.State
    public var volume: Int
    public private(set) var log: [String] = []
    private let lock = NSLock()
    public init(queue: [Track] = [Track(title: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue"),
                                  Track(title: "So What", artist: "Miles Davis", album: "Kind of Blue"),
                                  Track(title: "Naima", artist: "John Coltrane", album: "Giant Steps")],
                state: NowPlaying.State = .playing, volume: Int = 40) {
        self.queue = queue; self.state = state; self.volume = volume
    }
    public func play() async throws { lock.withLock { log.append("play"); state = .playing } }
    public func pause() async throws { lock.withLock { log.append("pause"); state = .paused } }
    public func next() async throws { lock.withLock { log.append("next"); index = (index + 1) % max(queue.count, 1) } }
    public func previous() async throws { lock.withLock { log.append("previous"); index = (index - 1 + max(queue.count, 1)) % max(queue.count, 1) } }
    public func setVolume(_ percent: Int) async throws { lock.withLock { log.append("volume \(percent)"); volume = percent } }
    public func nowPlaying() async throws -> NowPlaying {
        lock.withLock {
            log.append("now_playing")
            let t = queue.isEmpty ? nil : queue[index]
            return NowPlaying(state: state, title: t?.title, artist: t?.artist, album: t?.album, volume: volume)
        }
    }
}

public enum MusicStore {
    nonisolated(unsafe) private static var override: (any MusicSource)?
    private static let lock = NSLock()
    public static func use(_ source: (any MusicSource)?) { lock.lock(); override = source; lock.unlock() }
    public static var isFixture: Bool { lock.lock(); defer { lock.unlock() }; return override != nil }
    static var current: any MusicSource {
        lock.lock(); defer { lock.unlock() }
        if let o = override { return o }
        #if canImport(MediaPlayer) && os(iOS)
        return SystemMusicSource.shared
        #else
        return FixtureMusicSource()
        #endif
    }
}

#if canImport(MediaPlayer) && os(iOS)
/// `MPMusicPlayerController.systemMusicPlayer` — controls whatever the system is playing, without a queue of our own.
/// Volume goes through the slider inside an off-screen `MPVolumeView` (the only public way; iOS shows its HUD).
final class SystemMusicSource: MusicSource, @unchecked Sendable {
    static let shared = SystemMusicSource()
    private init() {}

    @MainActor private var player: MPMusicPlayerController { MPMusicPlayerController.systemMusicPlayer }

    func play() async throws { await MainActor.run { player.play() } }
    func pause() async throws { await MainActor.run { player.pause() } }
    func next() async throws { await MainActor.run { player.skipToNextItem() } }
    func previous() async throws {
        await MainActor.run {
            // Like the Lock Screen: within the first few seconds go to the previous song, otherwise restart this one.
            if player.currentPlaybackTime > 3 { player.skipToBeginning() } else { player.skipToPreviousItem() }
        }
    }

    @MainActor private static var volumeView: MPVolumeView?
    func setVolume(_ percent: Int) async throws {
        let target = Float(max(0, min(100, percent))) / 100
        let ended: Float? = await MainActor.run {
            let view: MPVolumeView
            if let v = Self.volumeView { view = v } else {
                view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
                view.isHidden = false; view.alpha = 0.01
                // Must live in a window for the slider to exist and for its value to reach the system.
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first else { return nil }
                window.addSubview(view)
                Self.volumeView = view
            }
            guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return nil }
            slider.setValue(target, animated: false)
            slider.sendActions(for: .valueChanged)   // what makes the system take the value
            return slider.value
        }
        // The slider commits on the next run-loop turn; give it one.
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard ended != nil else {
            throw ToolError("iOS does not let apps set the volume on this device — use the volume buttons or Control Centre")
        }
    }

    func nowPlaying() async throws -> NowPlaying {
        let auth = MPMediaLibrary.authorizationStatus()
        let status: MPMediaLibraryAuthorizationStatus
        if auth == .notDetermined { status = await withCheckedContinuation { c in MPMediaLibrary.requestAuthorization { c.resume(returning: $0) } } } else { status = auth }
        return await MainActor.run {
            let p = player
            let state: NowPlaying.State = switch p.playbackState {
            case .playing, .seekingForward, .seekingBackward: .playing
            case .paused, .interrupted: .paused
            default: .stopped
            }
            let item = status == .authorized ? p.nowPlayingItem : nil
            let vol = Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded())
            return NowPlaying(state: state, title: item?.title, artist: item?.artist, album: item?.albumTitle, volume: vol)
        }
    }
}
#endif

public struct MusicTool: AppleTool {
    public init() {}
    public let name = "music"
    // MEASURED on Qwen3.5-0.8B (MusicToolMeasurement, 3 runs × 5 scenarios, evidence in the lane folder):
    //  v1 "skip to the next or previous song…"           4/15 — "skip this song" → asked WHICH song 3/3; "what song is this?" → translate 3/3.
    //  v2 triggers named + louder/quieter in the enum     6/15 — pause 3/3, now_playing 2/3, but "turn it down to 20" → `louder{level:20}` 3/3:
    //                                                     a direction word in the enum beats the number every time.
    //  v3 (shipped) six actions, `level` takes a number OR up/down — the enum carries no direction, the level does.
    public let description = "The music playing on this iPhone right now (Apple Music or the system player). It always acts on the song that is playing — never ask which song. Use it the moment the user says pause, play, resume, stop, skip, next, previous, back, louder, quieter, volume, or asks what song is playing / what this is. action=volume sets the volume: level is a number 0–100, or up / down to change it a little. action=now_playing returns the title and artist."
    public let parameters: JSONValue = ToolSchema.object([
        "action": ["type": "string", "enum": ["play", "pause", "next", "previous", "volume", "now_playing"],
                   "description": "pause · play (resume) · next (skip the current song) · previous (go back) · volume (needs level) · now_playing (what song is this)"],
        "level": ToolSchema.string("For volume: 0–100, or up / down (louder / quieter)"),
    ], required: ["action"])
    public static let actions = ["play", "pause", "next", "previous", "volume", "now_playing"]
    /// How much `up` / `down` move the volume.
    public static let step = 15
    public static let onDeviceCopy = "Play, pause, skip and set the volume of whatever is playing on this iPhone, and say what it is. Nothing leaves the device."
    public static var defaultOn: Bool { true }

    public struct Request: Sendable, Hashable {
        public var action: String
        /// 0–100, present for `volume` with an absolute level.
        public var level: Int?
        /// ±`step`, present for `volume` with up / down.
        public var delta: Int?
    }

    /// Accepts the words small models actually emit: `action` or `command`, `resume`→play, `stop`→pause, `skip`→next,
    /// `back`→previous, `status`/`current`→now_playing, `louder`/`quieter`→volume up/down; `level` or `volume`/`percent`/`_`,
    /// "40%" strings, 0–1 fractions, and `up`/`down`/`+10`/`-10` for a relative change.
    public static func parse(_ args: [String: JSONValue]) throws -> Request {
        var a = (args.string("action") ?? args.string("command") ?? args.string("do") ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        var delta: Int? = nil
        switch a {
        case "resume", "start", "unpause": a = "play"
        case "stop", "halt": a = "pause"
        case "skip", "skip_next", "forward", "next_track", "next_song": a = "next"
        case "back", "prev", "skip_previous", "previous_track", "previous_song", "rewind": a = "previous"
        case "set_volume", "mute": a = "volume"
        case "louder", "volume_up", "up", "increase", "raise": a = "volume"; delta = step
        case "quieter", "volume_down", "down", "decrease", "lower", "softer": a = "volume"; delta = -step
        case "status", "current", "now", "nowplaying", "now-playing", "what_is_playing", "info", "": a = a.isEmpty && levelText(args) != nil ? "volume" : "now_playing"
        default: break
        }
        guard actions.contains(a) else { throw ToolError("action must be one of \(actions.joined(separator: ", "))") }
        var level: Int? = nil
        if a == "volume" {
            if let raw = levelText(args) {
                let t = raw.lowercased().replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                switch t {
                case "up", "louder", "higher", "more", "increase", "+": delta = step
                case "down", "quieter", "lower", "less", "decrease", "softer", "-": delta = -step
                case "mute", "off", "silent": level = 0
                case "max", "full", "loud": level = 100
                default:
                    if t.hasPrefix("+") || t.hasPrefix("-"), let d = Double(t) { delta = Int(d.rounded()) }
                    else if var v = Double(t) {
                        if v > 0, v < 1 { v *= 100 }   // 0.4 → 40
                        level = Int(max(0, min(100, v)).rounded())
                    } else { throw ToolError("level must be 0–100, or up / down") }
                }
            } else if delta == nil {
                throw ToolError("volume needs level: 0–100, or up / down")
            }
        }
        return Request(action: a, level: level, delta: delta)
    }
    private static func levelText(_ args: [String: JSONValue]) -> String? {
        for k in ["level", "volume", "percent", "value", "to", "_"] {
            if let d = args.double(k) { return String(d) }
            if let s = args.string(k), !s.isEmpty { return s }
        }
        return nil
    }

    public static func availability() -> ToolAvailability {
        if MusicStore.isFixture { return .ok }
        #if canImport(MediaPlayer) && os(iOS)
        if Unavailable.isSimulator { return .no(Unavailable.simulator) }
        return .ok
        #else
        return .no(Unavailable.noUIKit)
        #endif
    }

    /// The text the model reads.
    public static func render(_ np: NowPlaying, after action: String, level: Int? = nil) -> String {
        var lines: [String] = []
        switch action {
        case "play": lines.append("music: playing")
        case "pause": lines.append("music: paused")
        case "next": lines.append("music: skipped to the next song")
        case "previous": lines.append("music: went back")
        case "volume": lines.append("music: volume set to \(level ?? np.volume ?? 0)%")
        default: lines.append("music: \(np.state.rawValue)")
        }
        if let t = np.title {
            lines.append("now playing: \(t)" + (np.artist.map { " — \($0)" } ?? "") + (np.album.map { " (\($0))" } ?? ""))
        } else if action == "now_playing" || action == "next" || action == "previous" || action == "play" {
            lines.append(np.state == .stopped ? "nothing is queued — the user can start a song in the Music app" : "title unavailable (the user has not allowed access to the music library)")
        }
        if action != "volume", let v = np.volume { lines.append("volume: \(v)%") }
        return lines.joined(separator: "\n")
    }

    /// Phase 7: the mini player under every music result. Title falls back to "Music" when the library is not
    /// readable; the volume slider shows only when the tool knows the level.
    public static func control(_ np: NowPlaying, volume: Int? = nil) -> ToolControl {
        let subtitle = [np.artist, np.album].compactMap { $0 }.joined(separator: " · ")
        return .player(.init(title: np.title ?? (np.state == .stopped ? "Nothing queued" : "Music"),
                             subtitle: subtitle.isEmpty ? nil : subtitle,
                             playing: np.state == .playing, volume: volume ?? np.volume, tool: "music"))
    }

    public func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }

    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let r = try Self.parse(args)
        let a = Self.availability(); guard a.available else { throw ToolError("music is not available here: \(a.reason)") }
        let src = MusicStore.current
        switch r.action {
        case "play": try await src.play()
        case "pause": try await src.pause()
        case "next": try await src.next()
        case "previous": try await src.previous()
        case "volume":
            var target = r.level ?? 50
            if let d = r.delta {
                let now = (try? await src.nowPlaying().volume) ?? 50
                target = max(0, min(100, now + d))
            }
            try await src.setVolume(target)
            let np = try await src.nowPlaying()
            return ToolOutput(text: Self.render(np, after: "volume", level: target), control: Self.control(np, volume: target))
        default: break
        }
        let np = try await src.nowPlaying()
        return ToolOutput(text: Self.render(np, after: r.action, level: r.level), control: Self.control(np))
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}
