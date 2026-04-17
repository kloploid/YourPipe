# YourPipe (iOS MVP)

A SwiftUI iOS app for searching and playing YouTube videos with local
subscriptions and a mini player.

## Features

- Video / channel / playlist search
- Full-screen playback screen with AVKit
- Mini player pinned above the tab bar
- Local channel subscriptions (JSON-backed, on-device)
- Subscription feed of recent uploads
- Background audio and Picture-in-Picture (within iOS limits)

## Tech Stack

- SwiftUI + AVFoundation / AVKit
- XcodeGen (`project.yml`)
- InnerTube-based YouTube extractor with an ANDROID_VR → ANDROID → IOS
  client waterfall
- Optional Piped fallback (multi-instance)
- Local `AVAssetResourceLoaderDelegate` HLS proxy for on-the-fly
  n-param decoding

## Requirements

- Xcode 15+
- iOS 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Run

1. Generate the project:
   ```bash
   xcodegen generate
   ```
2. Open `YourPipe.xcodeproj`.
3. Build and run the `YourPipe` target.

## Project Structure

- `YourPipe/YourPipeApp.swift` — app entry, environment wiring
- `YourPipe/ContentView.swift` — tab shell and mini player bar
- `YourPipe/PlaybackController.swift` — AVPlayer orchestration, PiP,
  Now Playing, stream-refresh recovery
- `YourPipe/PlaybackResolver.swift` — cached resolver with inflight
  deduplication and first-byte warmup
- `YourPipe/YouTubePlaybackService.swift` — InnerTube client waterfall,
  n-param JS decoder, client cooldown / backoff, optional poToken hook
- `YourPipe/HLSProxy.swift` — HLS playlist rewriter for throttling
  parameter decoding
- `YourPipe/YouTubeSearchService.swift` — search / channel / feed
  parsing via InnerTube
- `YourPipe/SubscriptionStore.swift` — on-disk subscription persistence
- `YourPipe/AppSettingsStore.swift` — playback-source preference

## Playback Source Modes

Selectable from the in-app Settings tab:

- **Direct YouTube** — InnerTube clients only.
- **Piped proxy** — community Piped instances only.
- **Auto** — tries Direct first, falls back to Piped on failure.

## Anti-Ban Hardening

The direct path follows techniques used by NewPipe/yt-dlp to reduce
rate-limit and LOGIN_REQUIRED responses:

- Sequential client waterfall with randomised jitter between attempts
  (no parallel bursts from a single IP).
- Per-client cooldown with exponential backoff on 403 / 429 / anti-bot
  statuses, honouring `Retry-After`.
- Device-locale-based `hl` / `gl` / UTC offset (no hard-coded `en/US`).
- Lazy `visitorData` fetch — no cold-start request on app launch.
- Mid-playback 403 recovery: a fresh resolve with position-restore
  before any user-visible error is surfaced.
- Optional `PoTokenProvider` protocol; when a provider is installed the
  service appends `pot=` to stream URLs.

Client versions and n-param patterns should be re-synced periodically
against upstream references:

- yt-dlp — `yt_dlp/extractor/youtube/_base.py` (`INNERTUBE_CLIENTS`)
- NewPipeExtractor — `YoutubeParsingHelper.java`,
  `YoutubeThrottlingParameterUtils.java`

## Notes

- MVP-quality codebase, actively iterated on.
- Playback strategies depend on YouTube-side changes and may require
  recurring fixes. Treat the extractor layer as maintenance code.
