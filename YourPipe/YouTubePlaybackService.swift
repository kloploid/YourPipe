import Foundation
import JavaScriptCore

// MARK: - YouTubePlaybackService
// Client waterfall: ANDROID_VR → ANDROID → IOS
//
// References:
//   yt-dlp default clients (2025): android_vr, ios
//   github.com/TeamNewPipe/NewPipeExtractor — YoutubeStreamExtractor.java
//   github.com/zerodytrash/YouTube-Internal-Clients

/// Optional provider for YouTube's proof-of-origin token (poToken / "pot").
/// When present, the service will:
///   • include `serviceIntegrityDimensions.poToken` in the InnerTube payload
///   • append `pot=<token>` to the resolved stream URL
///
/// NewPipeExtractor's `PoTokenProvider` fulfils the same role. A full
/// implementation requires running YouTube's BotGuard challenge; this
/// protocol exists so that capability can be plugged in later without
/// changing call sites.
protocol PoTokenProvider: AnyObject {
    /// Returns a pot for the given (visitorData, videoId) pair, or nil if
    /// unavailable. Implementations should cache aggressively — fresh tokens
    /// are expensive to mint and remain valid for hours.
    func poToken(visitorData: String?, videoId: String) async -> String?
}

actor YouTubePlaybackService {
    static let shared = YouTubePlaybackService()

    /// Optional. When unset, pot is omitted entirely (today's default path).
    /// Install via `setPoTokenProvider` once a concrete provider exists.
    private weak var poTokenProvider: PoTokenProvider?

    func setPoTokenProvider(_ provider: PoTokenProvider?) {
        poTokenProvider = provider
    }

    private let session: URLSession

    // Client fingerprints. Keep these in sync with upstream references:
    //   • yt-dlp: yt_dlp/extractor/youtube/_base.py  (INNERTUBE_CLIENTS)
    //   • NewPipeExtractor: extractor/services/youtube/YoutubeParsingHelper.java
    // Outdated versions correlate with increased LOGIN_REQUIRED/403 rates.

    // ── IOS client (returns HLS; no PO token required for most videos) ───────
    private let iosClientName    = "IOS"
    private let iosClientVersion = "20.11.6"
    private let iosClientNameInt = "5"
    private let iosUserAgent     = "com.google.ios.youtube/20.11.6 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X;)"

    // ── ANDROID_VR client (yt-dlp default — no PO token, direct MP4) ─────────
    private let vrClientName    = "ANDROID_VR"
    private let vrClientVersion = "1.62.27"
    private let vrClientNameInt = "28"
    private let vrSdkVersion    = 32
    private let vrUserAgent     = "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    // ── ANDROID client (fallback) ─────────────────────────────────────────────
    private let androidClientName    = "ANDROID"
    private let androidClientVersion = "20.48.39"
    private let androidClientNameInt = "3"
    private let androidSdkVersion    = 34
    private let androidUserAgent     = "com.google.android.youtube/20.48.39 (Linux; U; Android 14; en_US) gzip"

    // Base InnerTube endpoint (no API key — avoids stale-key rejections)
    private let playerEndpoint = "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false"

    // Cached visitor data (obtained once per session, lazily)
    private var visitorData: String?
    private var visitorDataTask: Task<String?, Never>?

    // Local n-param decoder cache
    private var playerJSCache: [String: String] = [:]   // playerId → JS text
    private var nDecoderCache: [String: String] = [:]   // playerId → func body

    // Per-client cooldowns and consecutive-failure counters for exponential
    // backoff. A client is skipped entirely while cooled down; YouTube's
    // rate-limiters otherwise escalate further (LOGIN_REQUIRED, harder bans).
    private var clientCooldownUntil: [String: Date] = [:]
    private var clientFailureStreak: [String: Int] = [:]

    private let nonceAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private let resolveTimeout: TimeInterval = 8

    // Locale-derived client context. Using the device's real locale prevents a
    // gl/hl=US mismatch with the user's IP, which raises the anti-bot signal.
    private var localeHL: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
    private var localeGL: String {
        Locale.current.region?.identifier ?? "US"
    }
    private var localeUTCOffsetMinutes: Int {
        TimeZone.current.secondsFromGMT() / 60
    }
    private var acceptLanguageHeader: String {
        let hl = localeHL, gl = localeGL
        return "\(hl)-\(gl),\(hl);q=0.9,en;q=0.5"
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public types

    struct PlaybackData {
        let streamURL: URL
        let title: String?
        let channelName: String?
        let channelId: String?
        let description: String?
        let headers: [String: String]
        let playerId: String?
        let resolvedClient: String
    }

    enum ResolveStrategy {
        case fastest
        case exclude(client: String)
    }

    enum PlaybackError: LocalizedError {
        case invalidURL
        case invalidResponse
        case invalidJSON
        case httpStatus(Int, String)
        case noPlayableStream
        case notPlayable(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:              return "Не удалось сформировать запрос."
            case .invalidResponse:         return "Сервер вернул некорректный ответ."
            case .invalidJSON:             return "Не удалось разобрать ответ плеера."
            case .httpStatus(let c, _):    return "Ошибка загрузки видео: HTTP \(c)."
            case .noPlayableStream:        return "Для этого видео не найден поток воспроизведения."
            case .notPlayable(let reason): return "Видео недоступно: \(reason)"
            }
        }
    }

    // MARK: - Public API

    /// Tries ANDROID_VR → ANDROID → IOS sequentially. First success wins.
    /// Sequential (not parallel) — parallel resolve bursts to /player from one IP
    /// look bot-like and correlate with increased 403/LOGIN_REQUIRED rates.
    func resolve(videoId: String, strategy: ResolveStrategy = .fastest) async throws -> PlaybackData {
        await ensureVisitorData()

        let excluded: String? = {
            if case .exclude(let c) = strategy { return c } else { return nil }
        }()

        var failures: [String] = []

        let attempts: [(label: String, run: () async throws -> PlaybackData)] = [
            (vrClientName,      { try await self.resolveViaAndroidVR(videoId: videoId) }),
            (androidClientName, { try await self.resolveViaAndroid(videoId: videoId) }),
            (iosClientName,     { try await self.resolveViaIOS(videoId: videoId) }),
        ]

        for (idx, attempt) in attempts.enumerated() {
            if excluded == attempt.label { continue }
            if isCooledDown(client: attempt.label) {
                failures.append("\(attempt.label): cooldown")
#if DEBUG
                print("[YT] \(attempt.label) skipped (cooldown active)")
#endif
                continue
            }
            if idx > 0 { try? await jitterSleep() }
            do {
                let data = try await attempt.run()
                clearCooldown(client: attempt.label)
#if DEBUG
                print("[YT] resolved via \(attempt.label) client")
#endif
                return data
            } catch {
                failures.append("\(attempt.label): \(error.localizedDescription)")
#if DEBUG
                print("[YT] \(attempt.label) failed: \(error.localizedDescription)")
#endif
            }
        }

        throw PlaybackError.notPlayable(failures.joined(separator: " | "))
    }

    /// Small randomised gap (120–280 ms) between sequential client attempts — softens
    /// the "3 identical POSTs in 50ms" signature that rate-limiters pick up on.
    private func jitterSleep() async throws {
        let ms = UInt64.random(in: 120...280)
        try await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// Appends `pot=<token>` to a stream URL if the provider yields one.
    /// No-op when no provider is installed — stays a safe passthrough.
    private func addingPoTokenIfAvailable(to url: URL, videoId: String) async -> URL {
        guard let token = await currentPoToken(for: videoId), !token.isEmpty else { return url }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        if let idx = items.firstIndex(where: { $0.name == "pot" }) {
            items[idx].value = token
        } else {
            items.append(URLQueryItem(name: "pot", value: token))
        }
        comps.queryItems = items
        return comps.url ?? url
    }

    /// Returns the provider's current token for a video, or nil. Centralised
    /// so both stream-URL and InnerTube-body paths share one lookup per
    /// resolve (providers typically cache internally, so the second call is
    /// cheap, but we avoid double-logging etc.)
    private func currentPoToken(for videoId: String) async -> String? {
        guard let provider = poTokenProvider else { return nil }
        return await provider.poToken(visitorData: visitorData, videoId: videoId)
    }

    /// Builds the InnerTube `/player` payload. Centralising this keeps the
    /// three resolve methods in sync when fields are added (poToken, params,
    /// playbackContext, etc.).
    private func buildPlayerPayload(videoId: String, clientCtx: [String: Any]) async -> [String: Any] {
        var payload: [String: Any] = [
            "context": ["client": clientCtx, "user": ["lockedSafetyMode": false]],
            "videoId": videoId,
            "cpn": randomCPN(),
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        if let token = await currentPoToken(for: videoId), !token.isEmpty {
            payload["serviceIntegrityDimensions"] = ["poToken": token]
        }
        return payload
    }

    /// Ensures `visitorData` is available before first resolve. Lazy: called from
    /// resolve(), not from app start, so we don't emit a cold-start request that
    /// YouTube can fingerprint as "app just launched, no user action yet".
    /// Deduplicates concurrent callers via a shared Task.
    private func ensureVisitorData() async {
        if visitorData != nil { return }
        if let inflight = visitorDataTask {
            _ = await inflight.value
            return
        }
        let task = Task<String?, Never> { [weak self] in
            await self?.fetchVisitorData()
        }
        visitorDataTask = task
        let fetched = await task.value
        if visitorData == nil { visitorData = fetched }
        visitorDataTask = nil
#if DEBUG
        print("[YT] visitorData=\(visitorData ?? "nil")")
#endif
    }

    /// Called from HLSProxy — decode n-param locally.
    func decodeThrottlingURL(_ url: URL, playerId: String?) async -> URL {
        await decodeThrottlingIfNeeded(url: url, playerId: playerId)
    }

    // MARK: - Visitor Data

    private func fetchVisitorData() async -> String? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(iosUserAgent, forHTTPHeaderField: "User-Agent")
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": iosClientName,
                    "clientVersion": iosClientVersion,
                    "hl": localeHL, "gl": localeGL
                ]
            ],
            "browseId": "FEwhat_to_watch"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, _) = try await session.data(for: req)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ctx = root["responseContext"] as? [String: Any],
                  let vd = ctx["visitorData"] as? String else { return nil }
            return vd
        } catch { return nil }
    }

    // MARK: - IOS Client

    private func resolveViaIOS(videoId: String) async throws -> PlaybackData {
        guard let url = URL(string: playerEndpoint) else { throw PlaybackError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: resolveTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(iosUserAgent,        forHTTPHeaderField: "User-Agent")
        req.setValue(iosClientNameInt,    forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(iosClientVersion,    forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let vd = visitorData {
            req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientCtx: [String: Any] = [
            "clientName":    iosClientName,
            "clientVersion": iosClientVersion,
            "deviceMake":    "Apple",
            "deviceModel":   "iPhone16,2",
            "osName":        "iPhone",
            "osVersion":     "18.2.1.22D82",
            "hl": localeHL, "gl": localeGL, "utcOffsetMinutes": localeUTCOffsetMinutes
        ]
        if let vd = visitorData { clientCtx["visitorData"] = vd }

        let payload = await buildPlayerPayload(videoId: videoId, clientCtx: clientCtx)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let root = try await fetchPlayerRoot(request: req, client: iosClientName)

#if DEBUG
        if let ps = root["playabilityStatus"] as? [String: Any] {
            print("[YT/IOS] playability=\(ps["status"] ?? "?") reason=\(ps["reason"] ?? "ok")")
        }
        logStreams(root: root)
#endif

        try checkPlayability(root: root, client: iosClientName)

        let details   = root["videoDetails"] as? [String: Any]
        let title     = details?["title"] as? String
        let channel   = details?["author"] as? String
        let channelId = details?["channelId"] as? String
        let desc      = details?["shortDescription"] as? String

        let streaming = root["streamingData"] as? [String: Any]
        var playerId: String? = extractPlayerId(from: root)
        if playerId == nil, requiresNDecoding(in: streaming) {
            playerId = await fetchPlayerIdFromWatchPage(videoId: videoId)
        }
        let headers   = iosStreamHeaders(videoId: videoId)


        if let hlsStr = streaming?["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            let decoded = await decodeThrottlingIfNeeded(url: hlsURL, playerId: playerId)
            let final = await addingPoTokenIfAvailable(to: decoded, videoId: videoId)
#if DEBUG
            print("[YT/IOS] using HLS: \(final)")
#endif
            return PlaybackData(streamURL: final, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: iosClientName)
        }

        // IOS sometimes returns adaptive formats instead of HLS
        let formats = streaming?["formats"] as? [[String: Any]] ?? []
        if let muxURL = await pickBestMuxedURL(from: formats, playerId: playerId, startupPreferred: true) {
            let final = await addingPoTokenIfAvailable(to: muxURL, videoId: videoId)
            return PlaybackData(streamURL: final, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: iosClientName)
        }

        throw PlaybackError.noPlayableStream
    }

    // MARK: - ANDROID_VR Client

    private func resolveViaAndroidVR(videoId: String) async throws -> PlaybackData {
        guard let url = URL(string: playerEndpoint) else { throw PlaybackError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: resolveTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(vrUserAgent,         forHTTPHeaderField: "User-Agent")
        req.setValue(vrClientNameInt,     forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(vrClientVersion,     forHTTPHeaderField: "X-YouTube-Client-Version")
        if let vd = visitorData {
            req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientCtx: [String: Any] = [
            "clientName":       vrClientName,
            "clientVersion":    vrClientVersion,
            "androidSdkVersion": vrSdkVersion,
            "hl": localeHL, "gl": localeGL, "utcOffsetMinutes": localeUTCOffsetMinutes
        ]
        if let vd = visitorData { clientCtx["visitorData"] = vd }

        let payload = await buildPlayerPayload(videoId: videoId, clientCtx: clientCtx)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let root = try await fetchPlayerRoot(request: req, client: vrClientName)

#if DEBUG
        if let ps = root["playabilityStatus"] as? [String: Any] {
            print("[YT/ANDROID_VR] playability=\(ps["status"] ?? "?") reason=\(ps["reason"] ?? "ok")")
        }
        logStreams(root: root)
#endif

        try checkPlayability(root: root, client: vrClientName)

        let details   = root["videoDetails"] as? [String: Any]
        let title     = details?["title"] as? String
        let channel   = details?["author"] as? String
        let channelId = details?["channelId"] as? String
        let desc      = details?["shortDescription"] as? String
        let isLive    = details?["isLiveContent"] as? Bool ?? false

        let streaming = root["streamingData"] as? [String: Any]
        var playerId: String? = extractPlayerId(from: root)
        if playerId == nil, requiresNDecoding(in: streaming) {
            playerId = await fetchPlayerIdFromWatchPage(videoId: videoId)
        }
        let headers   = androidStreamHeaders(videoId: videoId, userAgent: vrUserAgent)

        // Muxed MP4 first — direct URL, no HLS proxy, far less 403-prone
        let formats = streaming?["formats"] as? [[String: Any]] ?? []
        if !isLive, let muxURL = await pickBestMuxedURL(from: formats, playerId: playerId, startupPreferred: true) {
            let final = await addingPoTokenIfAvailable(to: muxURL, videoId: videoId)
            return PlaybackData(streamURL: final, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: vrClientName)
        }

        // HLS fallback (live streams, or no muxed formats available)
        if let hlsStr = streaming?["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            let decoded = await decodeThrottlingIfNeeded(url: hlsURL, playerId: playerId)
            let final = await addingPoTokenIfAvailable(to: decoded, videoId: videoId)
            return PlaybackData(streamURL: final, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: vrClientName)
        }

        throw PlaybackError.noPlayableStream
    }

    // MARK: - ANDROID Client (fallback)

    private func resolveViaAndroid(videoId: String) async throws -> PlaybackData {
        guard let url = URL(string: playerEndpoint) else { throw PlaybackError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: resolveTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json",   forHTTPHeaderField: "Content-Type")
        req.setValue(androidUserAgent,     forHTTPHeaderField: "User-Agent")
        req.setValue(androidClientNameInt, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(androidClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let vd = visitorData {
            req.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientCtx: [String: Any] = [
            "clientName":        androidClientName,
            "clientVersion":     androidClientVersion,
            "androidSdkVersion": androidSdkVersion,
            "hl": localeHL, "gl": localeGL, "utcOffsetMinutes": localeUTCOffsetMinutes
        ]
        if let vd = visitorData { clientCtx["visitorData"] = vd }

        let payload = await buildPlayerPayload(videoId: videoId, clientCtx: clientCtx)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let root = try await fetchPlayerRoot(request: req, client: androidClientName)

#if DEBUG
        if let ps = root["playabilityStatus"] as? [String: Any] {
            print("[YT/ANDROID] playability=\(ps["status"] ?? "?") reason=\(ps["reason"] ?? "ok")")
        }
        logStreams(root: root)
#endif

        try checkPlayability(root: root, client: androidClientName)

        let details   = root["videoDetails"] as? [String: Any]
        let title     = details?["title"] as? String
        let channel   = details?["author"] as? String
        let channelId = details?["channelId"] as? String
        let desc      = details?["shortDescription"] as? String
        let isLive    = details?["isLiveContent"] as? Bool ?? false

        let streaming = root["streamingData"] as? [String: Any]
        var playerId: String? = extractPlayerId(from: root)
        if playerId == nil, requiresNDecoding(in: streaming) {
            playerId = await fetchPlayerIdFromWatchPage(videoId: videoId)
        }
        let headers   = androidStreamHeaders(videoId: videoId, userAgent: androidUserAgent)

        // Muxed MP4 first — direct URL, no HLS proxy, far less 403-prone
        let formats = streaming?["formats"] as? [[String: Any]] ?? []
        if !isLive, let muxURL = await pickBestMuxedURL(from: formats, playerId: playerId, startupPreferred: true) {
            let final = await addingPoTokenIfAvailable(to: muxURL, videoId: videoId)
            return PlaybackData(streamURL: final, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: androidClientName)
        }

        // HLS fallback (live streams, or no muxed formats available)
        if let hlsStr = streaming?["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsStr) {
            let decoded = await decodeThrottlingIfNeeded(url: hlsURL, playerId: playerId)
            let final = await addingPoTokenIfAvailable(to: decoded, videoId: videoId)
            return PlaybackData(streamURL: final, title: title, channelName: channel,
                                channelId: channelId, description: desc,
                                headers: headers, playerId: playerId, resolvedClient: androidClientName)
        }

        throw PlaybackError.noPlayableStream
    }

    // MARK: - Shared request helper

    private func fetchPlayerRoot(request: URLRequest, client: String) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaybackError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 403 || http.statusCode == 429 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After") as NSString?)?.doubleValue ?? 0
                applyCooldown(client: client, minSeconds: retryAfter)
            }
            throw PlaybackError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaybackError.invalidJSON
        }
        return root
    }

    // MARK: - Cooldown / backoff

    private func isCooledDown(client: String) -> Bool {
        guard let until = clientCooldownUntil[client] else { return false }
        if until <= Date() {
            clientCooldownUntil[client] = nil
            return false
        }
        return true
    }

    private func applyCooldown(client: String, minSeconds: Double = 0) {
        let streak = (clientFailureStreak[client] ?? 0) + 1
        clientFailureStreak[client] = streak
        // 2s, 4s, 8s, 16s, … capped at 5 min. Jitter ±15%.
        let base = min(pow(2.0, Double(streak)), 300)
        let jitter = Double.random(in: 0.85...1.15)
        let delay = max(minSeconds, base * jitter)
        clientCooldownUntil[client] = Date().addingTimeInterval(delay)
#if DEBUG
        print("[YT] cooldown \(client) for \(Int(delay))s (streak=\(streak))")
#endif
    }

    private func clearCooldown(client: String) {
        clientFailureStreak[client] = 0
        clientCooldownUntil[client] = nil
    }

    private func checkPlayability(root: [String: Any], client: String) throws {
        guard let ps = root["playabilityStatus"] as? [String: Any],
              let status = ps["status"] as? String else { return }
        guard status == "OK" else {
            let reason = ps["reason"] as? String ?? status
            // Certain statuses indicate anti-bot / rate-limit reactions from
            // YouTube rather than a per-video restriction. Cooling down the
            // client avoids hammering the same fingerprint and makes the
            // failure "visible" to the waterfall so the next client runs.
            if isAntiBotStatus(status: status, reason: reason) {
                applyCooldown(client: client)
            }
            throw PlaybackError.notPlayable(reason)
        }
    }

    private func isAntiBotStatus(status: String, reason: String) -> Bool {
        if status == "LOGIN_REQUIRED" { return true }
        let r = reason.lowercased()
        return r.contains("sign in to confirm")
            || r.contains("not a bot")
            || r.contains("unusual traffic")
    }

    // MARK: - Stream selection

    private func pickBestMuxedURL(
        from formats: [[String: Any]],
        playerId: String?,
        startupPreferred: Bool
    ) async -> URL? {
        let muxed = formats.filter {
            guard let mime = $0["mimeType"] as? String else { return false }
            let m = mime.lowercased()
            return m.contains("video/mp4") && m.contains("avc1") && m.contains("mp4a")
        }
        let ranked = muxed.sorted { lhs, rhs in
            formatScore(lhs, startupPreferred: startupPreferred) > formatScore(rhs, startupPreferred: startupPreferred)
        }
        for item in ranked.prefix(6) {
            guard let url = await resolveURL(from: item, playerId: playerId) else { continue }
            if hasRateBypass(url) { return url }
        }
        for item in ranked {
            if let url = await resolveURL(from: item, playerId: playerId) { return url }
        }
        return nil
    }

    private func formatScore(_ item: [String: Any], startupPreferred: Bool) -> Int {
        let width = item["width"] as? Int ?? 0
        let bitrate = item["bitrate"] as? Int ?? 0
        let itag = item["itag"] as? Int ?? -1
        var score = 0
        if itag == 18 { score += 140 }
        if startupPreferred {
            if width <= 480 { score += 90 }
            else if width <= 720 { score += 55 }
            else { score += 20 }
            score += min(bitrate / 80_000, 40)
        } else {
            score += min(width / 8, 180)
            score += min(bitrate / 60_000, 80)
        }
        return score
    }

    private func hasRateBypass(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return false
        }
        return items.contains { $0.name == "ratebypass" && ($0.value ?? "").lowercased() == "yes" }
    }

    private func resolveURL(from item: [String: Any], playerId: String?) async -> URL? {
        if let urlStr = item["url"] as? String, let url = URL(string: urlStr) {
            return await decodeThrottlingIfNeeded(url: url, playerId: playerId)
        }
        if let url = await resolveCipheredURL(from: item, playerId: playerId) {
            return await decodeThrottlingIfNeeded(url: url, playerId: playerId)
        }
        return nil
    }

    /// Decodes a `signatureCipher` (or legacy `cipher`) blob into a playable
    /// URL by routing the `s` value through PipePipe's remote sig decoder.
    /// Falls back to nil on any failure — the caller simply tries the next
    /// format.
    private func resolveCipheredURL(from item: [String: Any], playerId: String?) async -> URL? {
        guard let playerId else { return nil }
        let raw = (item["signatureCipher"] as? String) ?? (item["cipher"] as? String)
        guard let raw, !raw.isEmpty else { return nil }

        var parts: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            parts[key] = value
        }
        guard let urlStr = parts["url"], let baseURL = URL(string: urlStr) else { return nil }
        guard let encodedSig = parts["s"], !encodedSig.isEmpty else {
            // No signature to decode — URL is already playable as-is.
            return baseURL
        }
        let sigParam = parts["sp"] ?? "signature"

        do {
            let decodedSig = try await PipePipeDecoderClient.shared.decodeSig(
                playerId: playerId,
                value: encodedSig
            )
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                return baseURL
            }
            var items = components.queryItems ?? []
            if let i = items.firstIndex(where: { $0.name == sigParam }) {
                items[i].value = decodedSig
            } else {
                items.append(URLQueryItem(name: sigParam, value: decodedSig))
            }
            components.queryItems = items
            return components.url ?? baseURL
        } catch {
#if DEBUG
            print("[SigDecoder] failed: \(error.localizedDescription) — skipping ciphered format")
#endif
            return nil
        }
    }

    // MARK: - n-param throttling — local JavaScript decoder

    private func decodeThrottlingIfNeeded(url: URL, playerId: String?) async -> URL {
        guard let playerId else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard let nValue = items.first(where: { $0.name == "n" })?.value else { return url }

        do {
            let decoded = try await decodeNParam(nValue, playerId: playerId)
            if let index = items.firstIndex(where: { $0.name == "n" }) {
                items[index].value = decoded
            } else {
                items.append(URLQueryItem(name: "n", value: decoded))
            }
            components.queryItems = items
            return components.url ?? url
        } catch {
#if DEBUG
            print("[NDecoder] failed: \(error.localizedDescription) — using raw URL (may throttle)")
#endif
            return url
        }
    }

    private func decodeNParam(_ n: String, playerId: String) async throws -> String {
        // Primary path: remote PipePipe decoder. If it fails (network,
        // schema change, etc.) fall back to local JavaScriptCore so playback
        // stays resilient to single-source outages.
        do {
            return try await PipePipeDecoderClient.shared.decodeN(playerId: playerId, value: n)
        } catch {
#if DEBUG
            print("[NDecoder] remote decode failed (\(error.localizedDescription)) — falling back to local JS")
#endif
            let funcBody = try await getNDecoderFunction(playerId: playerId)
            return try runInJS(funcBody: funcBody, input: n)
        }
    }

    private func getNDecoderFunction(playerId: String) async throws -> String {
        if let cached = nDecoderCache[playerId] { return cached }
        let js = try await fetchPlayerJS(playerId: playerId)
        let body = try extractNDecoderBody(from: js)
        nDecoderCache[playerId] = body
        return body
    }

    private func fetchPlayerJS(playerId: String) async throws -> String {
        if let cached = playerJSCache[playerId] { return cached }
        let urlStr = "https://www.youtube.com/s/player/\(playerId)/player_ias.vflset/en_US/base.js"
        guard let url = URL(string: urlStr) else { throw NSError(domain: "NDecoder", code: 1) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw NSError(domain: "NDecoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Empty player.js"])
        }
        playerJSCache[playerId] = text
        return text
    }

    /// Mirrors YoutubeThrottlingParameterUtils — 8 regex patterns for resilience.
    private func extractNDecoderBody(from js: String) throws -> String {
        let callPatterns: [(String, Bool)] = [
            (#"\.get\("n"\)\)&&\(b=([a-zA-Z$_][\w$]*)\[(\d+)\]\(b\)"#, true),
            (#"\.get\("n"\)\)&&\(b=([a-zA-Z$_][\w$]*)\[0\]\(b\)"#,    true),
            (#"b=([a-zA-Z$_][\w$]*)\[0\]\(b\),c\.set\("n",b\)"#,       true),
            (#"\.get\("n"\)\)&&\(b=([a-zA-Z$_][\w$]*)\(b\)"#,          false),
            (#"b=([a-zA-Z$_][\w$]*)\(b\),c\.set\("n",b\)"#,            false),
        ]

        for (pattern, isArray) in callPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
                  match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: js) else { continue }

            let name = String(js[nameRange])
            let idx: Int = {
                guard isArray, match.numberOfRanges >= 3,
                      let r = Range(match.range(at: 2), in: js) else { return 0 }
                return Int(js[r]) ?? 0
            }()

            if isArray {
                if let body = extractFunctionFromArray(named: name, index: idx, js: js) {
#if DEBUG
                    print("[NDecoder] found via array pattern '\(name)[\(idx)]'")
#endif
                    return body
                }
            } else {
                if let body = extractNamedFunction(named: name, js: js) {
#if DEBUG
                    print("[NDecoder] found via direct pattern '\(name)'")
#endif
                    return body
                }
            }
        }

        throw NSError(domain: "NDecoder", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "n-decoder not found in player.js"])
    }

    private func extractFunctionFromArray(named name: String, index: Int, js: String) -> String? {
        for prefix in ["var \(name)=[", "\(name)=["] {
            guard let r = js.range(of: prefix) else { continue }
            if let body = extractFunctionAtIndex(js: js, arrayStart: r.upperBound, targetIndex: index) {
                return body
            }
        }
        return nil
    }

    private func extractFunctionAtIndex(js: String, arrayStart: String.Index, targetIndex: Int) -> String? {
        var i = arrayStart
        var count = 0
        while i < js.endIndex {
            if js[i] == "]" { break }
            let kw = "function"
            if js[i...].hasPrefix(kw) {
                if count == targetIndex {
                    return extractBalancedFunction(js: js, at: i)
                }
                count += 1
                if let end = findClosingBrace(js: js, from: i) { i = end; continue }
            }
            i = js.index(after: i)
        }
        return nil
    }

    private func extractNamedFunction(named name: String, js: String) -> String? {
        for prefix in ["var \(name)=function", "\(name)=function"] {
            guard let r = js.range(of: prefix),
                  let kwRange = js.range(of: "function", range: r.lowerBound..<js.endIndex) else { continue }
            return extractBalancedFunction(js: js, at: kwRange.lowerBound)
        }
        return nil
    }

    private func extractBalancedFunction(js: String, at start: String.Index) -> String? {
        var i = start
        while i < js.endIndex, js[i] != "{" { i = js.index(after: i) }
        guard let end = findClosingBrace(js: js, from: i) else { return nil }
        return String(js[start..<end])
    }

    private func findClosingBrace(js: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inStr: Character? = nil
        var escaped = false
        var i = start
        while i < js.endIndex {
            let c = js[i]
            defer { i = js.index(after: i) }
            if escaped              { escaped = false; continue }
            if c == "\\" && inStr != nil { escaped = true; continue }
            if let s = inStr        { if c == s { inStr = nil }; continue }
            if c == "\"" || c == "'" || c == "`" { inStr = c; continue }
            if c == "{"             { depth += 1 }
            else if c == "}"        { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    private func runInJS(funcBody: String, input: String) throws -> String {
        let ctx = JSContext()!
        var jsErr: JSValue?
        ctx.exceptionHandler = { _, e in jsErr = e }

        let safe = input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'",  with: "\\'")
        let script = "(function(){ var f=\(funcBody); return f('\(safe)'); })()"
        let result = ctx.evaluateScript(script)

        if let e = jsErr {
            throw NSError(domain: "NDecoder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "JS error: \(e.toString() ?? "?")"])
        }
        guard let out = result?.toString(), out != "undefined", out != "null", !out.isEmpty else {
            throw NSError(domain: "NDecoder", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "JS returned empty"])
        }
        return out
    }

    // MARK: - Player ID extraction

    private func extractPlayerId(from root: [String: Any]) -> String? {
        if let assets = root["assets"] as? [String: Any],
           let js = assets["js"] as? String { return parsePlayerId(from: js) }
        if let cfg = root["playerConfig"] as? [String: Any],
           let js = cfg["jsUrl"] as? String { return parsePlayerId(from: js) }
        return nil
    }

    private func fetchPlayerIdFromWatchPage(videoId: String) async -> String? {
        // Embed page is simpler HTML, less likely to be bot-detected, always contains player config
        if let id = await fetchPlayerIdFromPage(
            urlString: "https://www.youtube.com/embed/\(videoId)",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1"
        ) { return id }

        // Fallback to full watch page
        return await fetchPlayerIdFromPage(
            urlString: "https://www.youtube.com/watch?v=\(videoId)",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1"
        )
    }

    private func fetchPlayerIdFromPage(urlString: String, userAgent: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("CONSENT=YES+cb.20231221-07-p0.en+FX+; SOCS=CAE=", forHTTPHeaderField: "Cookie")
        do {
            let (data, _) = try await session.data(for: req)
            guard var html = String(data: data, encoding: .utf8) else { return nil }
            html = html.replacingOccurrences(of: "\\u002F", with: "/")
            return parsePlayerId(from: html)
        } catch { return nil }
    }

    private func parsePlayerId(from text: String) -> String? {
        let pattern = #"/s/player/([a-fA-F0-9]{8,})/"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func requiresNDecoding(in streaming: [String: Any]?) -> Bool {
        guard let streaming else { return false }
        let formats = (streaming["formats"] as? [[String: Any]] ?? [])
            + (streaming["adaptiveFormats"] as? [[String: Any]] ?? [])

        for format in formats {
            if let urlString = format["url"] as? String,
               urlString.contains("n=") {
                return true
            }
            if let cipher = format["signatureCipher"] as? String,
               cipher.contains("n%3D") || cipher.contains("n=") {
                return true
            }
            if let cipher = format["cipher"] as? String,
               cipher.contains("n%3D") || cipher.contains("n=") {
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    private func randomCPN() -> String {
        String((0..<16).map { _ in nonceAlphabet.randomElement()! })
    }

    private func iosStreamHeaders(videoId: String) -> [String: String] {
        var h: [String: String] = [
            "User-Agent":      iosUserAgent,
            "Origin":          "https://www.youtube.com",
            "Referer":         "https://www.youtube.com/watch?v=\(videoId)",
            "Accept-Language": acceptLanguageHeader
        ]
        if let vd = visitorData { h["X-Goog-Visitor-Id"] = vd }
        return h
    }

    private func androidStreamHeaders(videoId: String, userAgent: String) -> [String: String] {
        var h: [String: String] = [
            "User-Agent":      userAgent,
            "Origin":          "https://www.youtube.com",
            "Referer":         "https://www.youtube.com/watch?v=\(videoId)",
            "Accept-Language": acceptLanguageHeader
        ]
        if let vd = visitorData { h["X-Goog-Visitor-Id"] = vd }
        return h
    }

}

// MARK: - Debug logging

#if DEBUG
private extension YouTubePlaybackService {
    func logStreams(root: [String: Any]) {
        guard let s = root["streamingData"] as? [String: Any] else {
            print("[YT] no streamingData"); return
        }
        print("[YT] hlsManifestUrl=\(s["hlsManifestUrl"] ?? "nil")")
        print("[YT] dashManifestUrl=\(s["dashManifestUrl"] ?? "nil")")
        if let formats = s["formats"] as? [[String: Any]] {
            for f in formats {
                print("[YT] format itag=\(f["itag"] ?? "?") mime=\(f["mimeType"] ?? "?") hasURL=\(f["url"] != nil)")
            }
        }
    }
}
#endif
