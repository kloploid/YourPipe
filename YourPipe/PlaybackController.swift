import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import AVKit
import UIKit

@MainActor
final class PlaybackController: NSObject, ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var title: String?
    @Published var metaLine: String?
    @Published var channelName: String?
    @Published var channelAvatarURL: URL?
    @Published var channelId: String?
    @Published var thumbnailURL: URL?
    @Published var descriptionText: String?
    @Published var currentVideoId: String?
    @Published var presentation: Presentation?
    @Published var isPlayingState: Bool = false
    @Published var activeSourceLabel: String?

    struct Presentation: Identifiable {
        let id: String
        let videoId: String
        let title: String
        let metaLine: String?
        let channelName: String?
        let channelAvatarURL: URL?
        let thumbnailURL: URL?
        let channelId: String?
    }

    var isPlaying: Bool {
        isPlayingState
    }

    var hasActivePlayback: Bool {
        player != nil
    }

    private let playbackService = YouTubePlaybackService.shared
    private let resolver: PlaybackResolver
    private let settings: AppSettingsStore
    private var playerStatusObservation: NSKeyValueObservation?
    private var remoteCommandsConfigured = false
    private var tickTimer: Timer?
    private var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var hlsProxy: HLSProxy?
    private var isDeviceLocked = false
    private var artworkCache: [URL: MPMediaItemArtwork] = [:]
    private var currentArtwork: MPMediaItemArtwork?
    /// Fallback artwork used while the real thumbnail is still loading.
    /// iOS 17+ requires `MPMediaItemPropertyArtwork` to be present for the
    /// Now Playing widget's transport icons to render — without it you get
    /// tap regions but no glyphs.
    private lazy var placeholderArtwork: MPMediaItemArtwork = {
        let size = CGSize(width: 300, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(white: 0.08, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }()
    private var currentPlayerId: String?
    private var attemptedPipedRecoveryForVideoId: String?
    private var isRecoveringViaPiped = false
    private let pipedAutoFallbackEnabled = false
    private var attemptedStreamRefreshForVideoId: String?
    private var isRefreshingStream = false
    private var startupMetrics: StartupMetrics?
    private var firstFrameObserverToken: Any?
    private var readyWatchdogTask: Task<Void, Never>?
    private var startupRetryAttemptedForVideoId: String?
    private var startupStreamSignature: String?
    private let startupReadyTimeoutSeconds: UInt64 = 3
    private let startupInitialPeakBitRate: Double = 700_000
    private let enableStartupProbeLogs = false

    init(
        resolver: PlaybackResolver = .shared,
        settings: AppSettingsStore = .shared
    ) {
        self.resolver = resolver
        self.settings = settings
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        startTickTimer()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(notification)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDeviceLock()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isDeviceLocked = false
            }
        }
    }

    deinit {
        tickTimer?.invalidate()
    }

    func play(
        videoId: String,
        fallbackTitle: String,
        fallbackMetaLine: String?,
        fallbackChannelName: String?,
        fallbackChannelAvatarURL: URL?,
        fallbackThumbnailURL: URL?,
        fallbackChannelId: String?
    ) async {
        if currentVideoId == videoId, isLoading {
            return
        }
        if currentVideoId == videoId, player != nil, errorMessage == nil {
            return
        }

        isLoading = true
        errorMessage = nil
        currentVideoId = videoId
        title = fallbackTitle
        metaLine = fallbackMetaLine
        channelName = fallbackChannelName
        channelAvatarURL = fallbackChannelAvatarURL
        thumbnailURL = fallbackThumbnailURL
        channelId = fallbackChannelId
        descriptionText = nil
        currentPlayerId = nil
        activeSourceLabel = nil
        attemptedPipedRecoveryForVideoId = nil
        isRecoveringViaPiped = false
        attemptedStreamRefreshForVideoId = nil
        isRefreshingStream = false
        startupRetryAttemptedForVideoId = nil
        startupStreamSignature = nil
        startupMetrics = StartupMetrics(videoId: videoId)
        cancelReadyWatchdog()

        do {
            let playback = try await resolver.resolve(
                videoId: videoId,
                mode: settings.playbackSourceMode
            )
            startupMetrics?.resolveCompleted()
            title = playback.title ?? fallbackTitle
            channelName = playback.channelName ?? fallbackChannelName
            channelId = playback.channelId ?? fallbackChannelId
            descriptionText = playback.description
            currentPlayerId = playback.playerId
            activeSourceLabel = playback.sourceLabel
            startupStreamSignature = streamSignature(for: playback.streamURL)
            Task {
                await self.probeStream(url: playback.streamURL, headers: playback.headers)
            }
            let item = makePlayerItem(url: playback.streamURL, headers: playback.headers, playerId: playback.playerId)
            observe(item: item)
            player?.pause()
            removeFirstFrameObserverIfNeeded()
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            player = newPlayer
            attachFirstFrameObserver(player: newPlayer, videoId: videoId)
            ensureAudioSessionActive()
            newPlayer.playImmediately(atRate: 1.0)
            isPlayingState = true
            updateNowPlayingInfo()
            Task {
                await self.loadArtworkIfNeeded()
            }
            startReadyWatchdog(videoId: videoId, excludingDirectClient: playback.directClientLabel)
            isLoading = false
            return
        } catch {
            errorMessage = error.localizedDescription
            isPlayingState = false
            activeSourceLabel = nil
            isLoading = false
            cancelReadyWatchdog()
            return
        }
    }

    func present(
        videoId: String,
        title: String,
        metaLine: String?,
        channelName: String?,
        channelAvatarURL: URL?,
        thumbnailURL: URL?,
        channelId: String?
    ) {
        presentation = Presentation(
            id: videoId,
            videoId: videoId,
            title: title,
            metaLine: metaLine,
            channelName: channelName,
            channelAvatarURL: channelAvatarURL,
            thumbnailURL: thumbnailURL,
            channelId: channelId
        )

        Task {
            await resolver.prefetch(videoId: videoId, mode: settings.playbackSourceMode)
        }
        Task {
            await self.play(
                videoId: videoId,
                fallbackTitle: title,
                fallbackMetaLine: metaLine,
                fallbackChannelName: channelName,
                fallbackChannelAvatarURL: channelAvatarURL,
                fallbackThumbnailURL: thumbnailURL,
                fallbackChannelId: channelId
            )
        }
    }

    func presentCurrent() {
        guard let currentVideoId else { return }
        presentation = Presentation(
            id: currentVideoId,
            videoId: currentVideoId,
            title: title ?? "Без названия",
            metaLine: metaLine,
            channelName: channelName,
            channelAvatarURL: channelAvatarURL,
            thumbnailURL: thumbnailURL,
            channelId: channelId
        )
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlayingState = false
        } else {
            ensureAudioSessionActive()
            player.play()
            isPlayingState = true
        }
        updateNowPlayingInfo()
    }

    func stop() {
        player?.pause()
        cancelReadyWatchdog()
        removeFirstFrameObserverIfNeeded()
        player = nil
        playerStatusObservation = nil
        currentVideoId = nil
        isLoading = false
        presentation = nil
        isPlayingState = false
        descriptionText = nil
        currentPlayerId = nil
        currentArtwork = nil
        activeSourceLabel = nil
        attemptedPipedRecoveryForVideoId = nil
        isRecoveringViaPiped = false
        attemptedStreamRefreshForVideoId = nil
        isRefreshingStream = false
        startupMetrics = nil
        startupRetryAttemptedForVideoId = nil
        startupStreamSignature = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        stopPictureInPictureIfNeeded()
        pipController = nil
        playerLayer = nil
        hlsProxy = nil
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .active || phase == .background else { return }
#if DEBUG
        print("[ScenePhase] \(phase)")
#endif
        ensureAudioSessionActive()
        if phase == .background, isPlaying, !isDeviceLocked {
            startPictureInPictureIfPossible()
        } else if phase == .active {
            stopPictureInPictureIfNeeded()
        }
        updateNowPlayingInfo()
    }

    func attachPlayerLayer(_ layer: AVPlayerLayer) {
        guard playerLayer !== layer else { return }
        playerLayer = layer
        configurePictureInPicture(for: layer)
    }

    private func makePlayerItem(url: URL, headers: [String: String], playerId: String?) -> AVPlayerItem {
        let effectiveHeaders = headersForAsset(url: url, headers: headers)
        let options: [String: Any]? = effectiveHeaders.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": effectiveHeaders]
        if isHLS(url: url) {
            if shouldBypassHLSProxy(url: url) {
                hlsProxy = nil
                let item: AVPlayerItem
                if options == nil {
                    item = AVPlayerItem(url: url)
                } else {
                    let asset = AVURLAsset(url: url, options: options)
                    item = AVPlayerItem(asset: asset)
                }
                configureForFastStart(item)
                return item
            }

            let proxy = HLSProxy(
                originalURL: url,
                headers: headers,
                playerId: playerId,
                decoder: playbackService
            )
            hlsProxy = proxy
            let asset = AVURLAsset(url: proxy.proxiedURL, options: options)
            asset.resourceLoader.setDelegate(proxy, queue: proxy.queue)
            let item = AVPlayerItem(asset: asset)
            configureForFastStart(item)
            return item
        }

        hlsProxy = nil
        let item: AVPlayerItem
        if options == nil {
            item = AVPlayerItem(url: url)
        } else {
            let asset = AVURLAsset(url: url, options: options)
            item = AVPlayerItem(asset: asset)
        }
        configureForFastStart(item)
        return item
    }

    private func configureForFastStart(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 0
        item.preferredPeakBitRate = startupInitialPeakBitRate
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    }

    private func isHLS(url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains(".m3u8") || lower.contains("hls")
    }

    private func shouldBypassHLSProxy(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "manifest.googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }

    private func headersForAsset(url: URL, headers: [String: String]) -> [String: String] {
        guard let host = url.host?.lowercased() else { return headers }
        if host == "manifest.googlevideo.com" || host.hasSuffix(".googlevideo.com") {
            // Signed Googlevideo URLs should be requested without custom headers.
            return [:]
        }
        return headers
    }

    private func probeStream(url: URL, headers: [String: String]) async {
#if DEBUG
        guard enableStartupProbeLogs else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let effectiveHeaders = headersForAsset(url: url, headers: headers)
        effectiveHeaders.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            let acceptRanges = http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "unknown"
            let contentLength = http?.value(forHTTPHeaderField: "Content-Length") ?? "unknown"
            let prefix = String(data: data.prefix(64), encoding: .utf8) ?? "binary"
            print("[VideoPlayback] probe status=\(status) contentType=\(contentType) acceptRanges=\(acceptRanges) contentLength=\(contentLength) prefix=\(prefix)")
        } catch {
            print("[VideoPlayback] probe failed: \(error)")
        }
#endif
    }

    private func observe(item: AVPlayerItem) {
        playerStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] playerItem, _ in
            guard let self else { return }
            if playerItem.status == .readyToPlay {
                Task { @MainActor in
                    self.cancelReadyWatchdog()
                    self.startupMetrics?.readyToPlay()
                }
            }
            if playerItem.status == .failed {
                let nsError = playerItem.error as NSError?
                let code = nsError?.code ?? -1
                let domain = nsError?.domain ?? "AVPlayer"
                let reason = nsError?.localizedFailureReason ?? nsError?.localizedDescription ?? "Unknown"
                let underlying = (nsError?.userInfo[NSUnderlyingErrorKey] as? NSError)
                let underlyingDesc = underlying?.localizedDescription ?? "none"
                Task { @MainActor in
                    self.errorMessage = "Поток AVPlayer недоступен (\(domain):\(code)) \(reason)"
                    print("[VideoPlayback] AVPlayer failed domain=\(domain) code=\(code) reason=\(reason) underlying=\(underlyingDesc)")
                    let refreshed = await self.refreshStreamIfNeeded(triggerError: nsError, underlying: underlying)
                    if !refreshed {
                        await self.recoverViaPipedIfNeeded(triggerError: nsError, underlying: underlying)
                    }
                }
            }
        }
    }

    private func attachFirstFrameObserver(player: AVPlayer, videoId: String) {
        removeFirstFrameObserverIfNeeded()
        firstFrameObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard time.seconds > 0 else { return }
                guard self.currentVideoId == videoId else { return }
                player.currentItem?.preferredPeakBitRate = 0
                self.startupMetrics?.firstFrame()
                self.removeFirstFrameObserverIfNeeded()
            }
        }
    }

    private func removeFirstFrameObserverIfNeeded() {
        guard let token = firstFrameObserverToken else { return }
        player?.removeTimeObserver(token)
        firstFrameObserverToken = nil
    }

    /// First-line recovery for 403/forbidden errors mid-playback: YouTube stream
    /// URLs can be revoked under rate-limit, but a fresh resolve with the same
    /// mode usually returns a working URL. We seek back to the last position
    /// so the user doesn't visibly jump. Runs before Piped fallback.
    /// Returns true if a refresh was attempted.
    @discardableResult
    private func refreshStreamIfNeeded(triggerError: NSError?, underlying: NSError?) async -> Bool {
        guard !isRefreshingStream else { return true }
        guard let videoId = currentVideoId else { return false }
        guard attemptedStreamRefreshForVideoId != videoId else { return false }
        guard shouldRetryWithPiped(triggerError: triggerError, underlying: underlying) else { return false }

        attemptedStreamRefreshForVideoId = videoId
        isRefreshingStream = true
        isLoading = true
        let resumeAt = player?.currentTime() ?? .zero

        defer {
            isRefreshingStream = false
            isLoading = false
        }

        do {
            let playback = try await resolver.resolve(
                videoId: videoId,
                mode: settings.playbackSourceMode,
                forceRefresh: true
            )
            let newSignature = streamSignature(for: playback.streamURL)
            if newSignature == startupStreamSignature {
#if DEBUG
                print("[VideoPlayback] stream refresh returned identical signature, skipping")
#endif
                return false
            }
            startupStreamSignature = newSignature
            currentPlayerId = playback.playerId
            activeSourceLabel = playback.sourceLabel
            let item = makePlayerItem(url: playback.streamURL, headers: playback.headers, playerId: playback.playerId)
            observe(item: item)
            player?.pause()
            removeFirstFrameObserverIfNeeded()
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            player = newPlayer
            attachFirstFrameObserver(player: newPlayer, videoId: videoId)
            ensureAudioSessionActive()
            if resumeAt.seconds > 1 {
                await newPlayer.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            newPlayer.playImmediately(atRate: 1.0)
            isPlayingState = true
            errorMessage = nil
            updateNowPlayingInfo()
#if DEBUG
            print("[VideoPlayback] stream refreshed, resuming at \(Int(resumeAt.seconds))s")
#endif
            return true
        } catch {
#if DEBUG
            print("[VideoPlayback] stream refresh failed: \(error.localizedDescription)")
#endif
            return false
        }
    }

    private func recoverViaPipedIfNeeded(triggerError: NSError?, underlying: NSError?) async {
        guard pipedAutoFallbackEnabled else { return }
        guard settings.playbackSourceMode == .auto else { return }
        guard !isRecoveringViaPiped else { return }
        guard activeSourceLabel != "Piped" else { return }
        guard let videoId = currentVideoId else { return }
        guard attemptedPipedRecoveryForVideoId != videoId else { return }
        guard shouldRetryWithPiped(triggerError: triggerError, underlying: underlying) else { return }

        attemptedPipedRecoveryForVideoId = videoId
        isRecoveringViaPiped = true
        isLoading = true

        do {
            let playback = try await resolver.resolve(videoId: videoId, mode: .piped)
            title = playback.title ?? title
            channelName = playback.channelName ?? channelName
            channelId = playback.channelId ?? channelId
            descriptionText = playback.description ?? descriptionText
            currentPlayerId = playback.playerId
            activeSourceLabel = playback.sourceLabel
            Task {
                await self.probeStream(url: playback.streamURL, headers: playback.headers)
            }
            let item = makePlayerItem(url: playback.streamURL, headers: playback.headers, playerId: playback.playerId)
            observe(item: item)
            player?.pause()
            removeFirstFrameObserverIfNeeded()
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            player = newPlayer
            attachFirstFrameObserver(player: newPlayer, videoId: videoId)
            ensureAudioSessionActive()
            newPlayer.playImmediately(atRate: 1.0)
            isPlayingState = true
            errorMessage = nil
            updateNowPlayingInfo()
            Task {
                await self.loadArtworkIfNeeded()
            }
            cancelReadyWatchdog()
            print("[VideoPlayback] recovered via Piped fallback")
        } catch {
            let previous = errorMessage ?? "Поток AVPlayer недоступен."
            errorMessage = "\(previous)\nFallback Piped: \(error.localizedDescription)"
            isPlayingState = false
            print("[VideoPlayback] Piped fallback failed: \(error.localizedDescription)")
        }

        isLoading = false
        isRecoveringViaPiped = false
    }

    private func shouldRetryWithPiped(triggerError: NSError?, underlying: NSError?) -> Bool {
        if let triggerError {
            if triggerError.domain == NSURLErrorDomain && triggerError.code == -1102 {
                return true
            }
            if triggerError.domain == "CoreMediaErrorDomain" && triggerError.code == -12660 {
                return true
            }
            let text = "\(triggerError.localizedDescription) \(triggerError.localizedFailureReason ?? "")".lowercased()
            if text.contains("403") || text.contains("forbidden") || text.contains("permission") {
                return true
            }
        }

        if let underlying {
            if underlying.domain == NSURLErrorDomain && underlying.code == -1102 {
                return true
            }
            if underlying.domain == "CoreMediaErrorDomain" && underlying.code == -12660 {
                return true
            }
            let text = "\(underlying.localizedDescription) \(underlying.localizedFailureReason ?? "")".lowercased()
            if text.contains("403") || text.contains("forbidden") || text.contains("permission") {
                return true
            }
        }

        return false
    }

    private func startReadyWatchdog(videoId: String, excludingDirectClient: String?) {
        cancelReadyWatchdog()
        guard settings.playbackSourceMode != .piped else { return }
        guard let excludingDirectClient, !excludingDirectClient.isEmpty else { return }

        readyWatchdogTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.startupReadyTimeoutSeconds * 1_000_000_000)
            await self.performStartupRetryIfNeeded(videoId: videoId, excludingDirectClient: excludingDirectClient)
        }
    }

    private func cancelReadyWatchdog() {
        readyWatchdogTask?.cancel()
        readyWatchdogTask = nil
    }

    private func performStartupRetryIfNeeded(videoId: String, excludingDirectClient: String) async {
        guard currentVideoId == videoId else { return }
        guard startupRetryAttemptedForVideoId != videoId else { return }
        guard player?.currentItem?.status != .readyToPlay else { return }
        guard shouldRetryStartupNow() else { return }
        guard !Task.isCancelled else { return }

        startupRetryAttemptedForVideoId = videoId
        isLoading = true
#if DEBUG
        print("[Startup] video=\(videoId) retrying startup via alternate client, excluding=\(excludingDirectClient)")
#endif
        do {
            let playback = try await resolver.resolve(
                videoId: videoId,
                mode: .direct,
                forceRefresh: true,
                excludingDirectClient: excludingDirectClient
            )
            title = playback.title ?? title
            channelName = playback.channelName ?? channelName
            channelId = playback.channelId ?? channelId
            descriptionText = playback.description ?? descriptionText
            currentPlayerId = playback.playerId
            activeSourceLabel = playback.sourceLabel
            let newSignature = streamSignature(for: playback.streamURL)
            if newSignature == startupStreamSignature {
#if DEBUG
                print("[Startup] video=\(videoId) retry skipped: same stream signature")
#endif
                isLoading = false
                return
            }
            startupStreamSignature = newSignature
            Task {
                await self.probeStream(url: playback.streamURL, headers: playback.headers)
            }
            let item = makePlayerItem(url: playback.streamURL, headers: playback.headers, playerId: playback.playerId)
            observe(item: item)
            player?.pause()
            removeFirstFrameObserverIfNeeded()
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = false
            player = newPlayer
            attachFirstFrameObserver(player: newPlayer, videoId: videoId)
            ensureAudioSessionActive()
            newPlayer.playImmediately(atRate: 1.0)
            isPlayingState = true
            errorMessage = nil
            updateNowPlayingInfo()
            Task {
                await self.loadArtworkIfNeeded()
            }
            startReadyWatchdog(videoId: videoId, excludingDirectClient: playback.directClientLabel)
        } catch {
#if DEBUG
            print("[Startup] video=\(videoId) retry failed: \(error.localizedDescription)")
#endif
        }

        isLoading = false
    }

    private func shouldRetryStartupNow() -> Bool {
        guard let item = player?.currentItem else { return true }
        if item.status == .readyToPlay || item.isPlaybackLikelyToKeepUp {
            return false
        }
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else {
            return true
        }
        let bufferedSeconds = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
        return bufferedSeconds < 0.8
    }

    private func streamSignature(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let id = components?.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
        let itag = components?.queryItems?.first(where: { $0.name == "itag" })?.value ?? ""
        return "\(host)|\(path)|\(id)|\(itag)"
    }

    private func ensureAudioSessionActive() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.moviePlayback` is the AVAudioSession.Mode designed for apps
            // that play movies / video-with-audio. It tells iOS to route the
            // Now Playing widget through the video-player variant, which
            // reliably renders transport icons. `.default` leaves the
            // widget's icon rendering in an ambiguous state on some iOS
            // builds (tap regions present, glyphs missing).
            try session.setCategory(
                .playback,
                mode: .moviePlayback
            )
            try session.setActive(true)
#if DEBUG
            print("[AudioSession] category=\(session.category.rawValue) mode=\(session.mode.rawValue) active=\(session.isOtherAudioPlaying ? "other-audio" : "ok")")
#endif
        } catch {
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
#if DEBUG
                print("[AudioSession] fallback category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
#endif
            } catch {
                print("Audio session activation failed: \(error)")
            }
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .ended {
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), isPlaying {
                ensureAudioSessionActive()
                player?.play()
            }
        }
    }

    private func handleDeviceLock() {
        // The app declares UIBackgroundModes = ["audio"], so audio must keep
        // playing when the device locks. We only stop PiP (the video layer
        // is suspended by the system anyway) and refresh Now Playing so the
        // lock-screen widget stays in sync with the still-playing AVPlayer.
        isDeviceLocked = true
        stopPictureInPictureIfNeeded()
        updateNowPlayingInfo()
    }

    private func configureAudioSession() {
        ensureAudioSessionActive()
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()

        // iOS 18+ widget rules:
        // 1. Enabled commands with a registered target render icons in the
        //    Now Playing widget. The widget picks its layout from the set of
        //    enabled commands at the time playbackState first becomes
        //    `.playing`.
        // 2. Commands with a target but left at the default isEnabled value
        //    sometimes render as tap-regions without glyphs (our previous
        //    bug). Set isEnabled = true explicitly to lock in the layout.
        // 3. Unused commands must be explicitly disabled — otherwise iOS
        //    may reserve an empty slot in the widget and cannibalise the
        //    space we need for play/pause.

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.ensureAudioSessionActive()
            self.player?.play()
            self.isPlayingState = true
            self.updateNowPlayingInfo()
            return .success
        }
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.player?.pause()
            self.isPlayingState = false
            self.updateNowPlayingInfo()
            return .success
        }
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let player = self.player,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let target = CMTime(seconds: positionEvent.positionTime, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateNowPlayingInfo()
                }
            }
            return .success
        }

        // Skip ±15s. Registering these makes iOS show the ±15 icons on
        // the lock-screen widget instead of (unsupported) track navigation.
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let player = self.player,
                  let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            let now = player.currentTime().seconds
            let target = CMTime(seconds: now + skipEvent.interval, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateNowPlayingInfo()
                }
            }
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, let player = self.player,
                  let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            let now = player.currentTime().seconds
            let target = CMTime(seconds: max(0, now - skipEvent.interval), preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateNowPlayingInfo()
                }
            }
            return .success
        }

        // Explicitly disable commands we do NOT support — otherwise iOS 18
        // may reserve widget real estate for them and end up with an empty
        // slot instead of our play/pause button.
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
        commandCenter.ratingCommand.isEnabled = false
        commandCenter.likeCommand.isEnabled = false
        commandCenter.dislikeCommand.isEnabled = false
        commandCenter.bookmarkCommand.isEnabled = false
        if #available(iOS 14.0, *) {
            commandCenter.changeRepeatModeCommand.isEnabled = false
            commandCenter.changeShuffleModeCommand.isEnabled = false
        }
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let player = self.player {
                    self.isPlayingState = (player.timeControlStatus == .playing)
                } else {
                    self.isPlayingState = false
                }
                self.updateNowPlayingInfo()
            }
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()

        guard currentVideoId != nil else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        // Guard against NaN: `player.currentTime().seconds` returns NaN
        // before the HLS manifest resolves. NaN inside `nowPlayingInfo` is a
        // known cause of the widget rendering glyphless transport controls
        // (tap regions present, icons missing).
        let rawElapsed = player?.currentTime().seconds ?? 0
        let elapsed = (rawElapsed.isFinite && rawElapsed >= 0) ? rawElapsed : 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title ?? "Без названия",
            MPMediaItemPropertyArtist: channelName ?? "Канал",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if let rawDuration = player?.currentItem?.duration.seconds,
           rawDuration.isFinite, rawDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = rawDuration
        }

        // Artwork is required on iOS 17+ for the widget's transport icons
        // to render. Use a placeholder until the real thumbnail loads.
        info[MPMediaItemPropertyArtwork] = currentArtwork ?? placeholderArtwork

        center.nowPlayingInfo = info
#if DEBUG
        print("[NowPlaying] title=\(title ?? "-") rate=\(info[MPNowPlayingInfoPropertyPlaybackRate] ?? "-") elapsed=\(elapsed) duration=\(info[MPMediaItemPropertyPlaybackDuration] ?? "none") artwork=\(currentArtwork != nil ? "real" : "placeholder")")
#endif

        // iOS 13+ explicit playback state — the authoritative signal for
        // the Now Playing widget. Update it unconditionally; the underlying
        // setter is cheap and idempotent.
        if player == nil {
            center.playbackState = .stopped
        } else if isPlaying {
            center.playbackState = .playing
        } else {
            center.playbackState = .paused
        }
    }

    private func loadArtworkIfNeeded() async {
        guard let url = thumbnailURL else { return }
        if let cached = artworkCache[url] {
            currentArtwork = cached
            updateNowPlayingInfo()
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                artworkCache[url] = artwork
                currentArtwork = artwork
                updateNowPlayingInfo()
            }
        } catch {
            // Ignore artwork errors.
        }
    }

    private func configurePictureInPicture(for layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.delegate = self
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        pipController = controller
    }

    private func startPictureInPictureIfPossible() {
        guard let controller = pipController,
              !controller.isPictureInPictureActive,
              controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    private func stopPictureInPictureIfNeeded() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }
}

extension PlaybackController: AVPictureInPictureControllerDelegate {}

private struct StartupMetrics {
    let videoId: String
    private let startedAt = Date()
    private(set) var didLogResolve = false
    private(set) var didLogReady = false
    private(set) var didLogFirstFrame = false

    private func elapsedMs() -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1000)
    }

    mutating func resolveCompleted() {
        guard !didLogResolve else { return }
        didLogResolve = true
        print("[Startup] video=\(videoId) resolve_ms=\(elapsedMs())")
    }

    mutating func readyToPlay() {
        guard !didLogReady else { return }
        didLogReady = true
        print("[Startup] video=\(videoId) ready_ms=\(elapsedMs())")
    }

    mutating func firstFrame() {
        guard !didLogFirstFrame else { return }
        didLogFirstFrame = true
        print("[Startup] video=\(videoId) first_frame_ms=\(elapsedMs())")
    }
}
