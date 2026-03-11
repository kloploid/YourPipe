import Foundation

actor YouTubePlaybackService {
    static let shared = YouTubePlaybackService()

    private let session: URLSession
    private let iosKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
    private let iosClientVersion = "21.03.2"
    private let iosDeviceModel = "iPhone16,2"
    private let iosOSVersion = "18.7.2.22H124"
    private let iosUserAgentVersion = "18_7_2"
    private let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
    private let nonceAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct PlaybackData {
        let streamURL: URL
        let title: String?
        let channelName: String?
        let channelId: String?
        let headers: [String: String]
    }

    enum PlaybackError: LocalizedError {
        case invalidURL
        case invalidResponse
        case invalidJSON
        case httpStatus(Int, String)
        case noPlayableStream

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Не удалось сформировать запрос плеера."
            case .invalidResponse:
                return "Сервер плеера вернул некорректный ответ."
            case .invalidJSON:
                return "Не удалось разобрать ответ плеера."
            case .httpStatus(let code, _):
                return "Ошибка загрузки видео: HTTP \(code)."
            case .noPlayableStream:
                return "Для этого видео не найден встроенный поток воспроизведения."
            }
        }
    }

    func resolve(videoId: String) async throws -> PlaybackData {
        return try await resolveViaInnerTube(videoId: videoId)
    }

    private func resolveViaInnerTube(videoId: String) async throws -> PlaybackData {
        var components = URLComponents(string: "https://youtubei.googleapis.com/youtubei/v1/player")!
        let t = String((0..<12).map { _ in nonceAlphabet.randomElement()! })
        components.queryItems = [
            URLQueryItem(name: "key", value: iosKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
            URLQueryItem(name: "t", value: t),
            URLQueryItem(name: "id", value: videoId)
        ]
        guard let url = components.url else { throw PlaybackError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(iosUserAgent(countryCode: "US"), forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "X-Goog-Api-Format-Version")

        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": iosClientVersion,
                    "deviceMake": "Apple",
                    "deviceModel": iosDeviceModel,
                    "platform": "MOBILE",
                    "osName": "iOS",
                    "osVersion": iosOSVersion,
                    "hl": "en",
                    "gl": "US",
                    "utcOffsetMinutes": 0
                ],
                "user": [
                    "lockedSafetyMode": false
                ]
            ],
            "videoId": videoId,
            "cpn": String((0..<16).map { _ in nonceAlphabet.randomElement()! }),
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlaybackError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PlaybackError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw PlaybackError.invalidJSON
        }

#if DEBUG
        if let playability = root["playabilityStatus"] as? [String: Any] {
            let status = playability["status"] as? String ?? "unknown"
            let reason = playability["reason"] as? String ?? "none"
            print("[YouTubePlaybackService] InnerTube playability status=\(status) reason=\(reason)")
        }
#endif

        logStreamingDataIfNeeded(root: root, source: "InnerTube")

        let title = (root["videoDetails"] as? [String: Any])?["title"] as? String
        let channelName = (root["videoDetails"] as? [String: Any])?["author"] as? String
        let channelId = (root["videoDetails"] as? [String: Any])?["channelId"] as? String

        if let hls = ((root["streamingData"] as? [String: Any])?["hlsManifestUrl"] as? String),
           let url = URL(string: hls) {
#if DEBUG
            print("[YouTubePlaybackService] InnerTube: using hlsManifestUrl")
#endif
            return PlaybackData(
                streamURL: url,
                title: title,
                channelName: channelName,
                channelId: channelId,
                headers: streamHeaders(videoId: videoId, userAgent: iosUserAgent(countryCode: "US"))
            )
        }

        let formats = ((root["streamingData"] as? [String: Any])?["formats"] as? [[String: Any]]) ?? []
        if let directURL = pickBestMuxedMP4URL(from: formats) {
#if DEBUG
            print("[YouTubePlaybackService] InnerTube: using muxed format url")
#endif
            return PlaybackData(
                streamURL: directURL,
                title: title,
                channelName: channelName,
                channelId: channelId,
                headers: streamHeaders(videoId: videoId, userAgent: iosUserAgent(countryCode: "US"))
            )
        }

        throw PlaybackError.noPlayableStream
    }

    private func resolveViaWatchPage(videoId: String) async throws -> PlaybackData {
        let watchURLString = "https://www.youtube.com/watch?v=\(videoId)"
        guard let watchURL = URL(string: watchURLString) else { throw PlaybackError.invalidURL }

        var request = URLRequest(url: watchURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CONSENT=PENDING+527", forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlaybackError.invalidResponse
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw PlaybackError.invalidResponse
        }

        guard let playerJSON = extractPlayerResponseJSON(from: html),
              let jsonData = playerJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
            throw PlaybackError.invalidJSON
        }

        logStreamingDataIfNeeded(root: root, source: "WatchPage")

        let title = (root["videoDetails"] as? [String: Any])?["title"] as? String
        let channelName = (root["videoDetails"] as? [String: Any])?["author"] as? String
        let channelId = (root["videoDetails"] as? [String: Any])?["channelId"] as? String

        let streamingData = root["streamingData"] as? [String: Any]
        if let hls = streamingData?["hlsManifestUrl"] as? String,
           let url = URL(string: hls) {
#if DEBUG
            print("[YouTubePlaybackService] WatchPage: using hlsManifestUrl")
#endif
            return PlaybackData(
                streamURL: url,
                title: title,
                channelName: channelName,
                channelId: channelId,
                headers: streamHeaders(videoId: videoId, userAgent: webUserAgent)
            )
        }
        if let formats = streamingData?["formats"] as? [[String: Any]],
           let directURL = pickBestMuxedMP4URL(from: formats) {
#if DEBUG
            print("[YouTubePlaybackService] WatchPage: using muxed format url")
#endif
            return PlaybackData(
                streamURL: directURL,
                title: title,
                channelName: channelName,
                channelId: channelId,
                headers: streamHeaders(videoId: videoId, userAgent: webUserAgent)
            )
        }

        throw PlaybackError.noPlayableStream
    }

    private func pickBestMuxedMP4URL(from formats: [[String: Any]]) -> URL? {
        let muxed = formats.filter { isMuxedMP4($0) }

        // Prefer itag=18 (H.264 + AAC, muxed MP4) when available.
        if let itag18 = muxed.first(where: { ($0["itag"] as? Int) == 18 }),
           let urlString = itag18["url"] as? String,
           let url = URL(string: urlString) {
            return url
        }

        let sorted = muxed.sorted { lhs, rhs in
            let lw = lhs["width"] as? Int ?? 0
            let rw = rhs["width"] as? Int ?? 0
            if lw == rw {
                let lbit = lhs["bitrate"] as? Int ?? 0
                let rbit = rhs["bitrate"] as? Int ?? 0
                return lbit > rbit
            }
            return lw > rw
        }

        for item in sorted {
            if let urlString = item["url"] as? String, let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    private func isMuxedMP4(_ item: [String: Any]) -> Bool {
        guard let mime = item["mimeType"] as? String else { return false }
        let lower = mime.lowercased()
        // Expect container mp4 with both video (avc1) and audio (mp4a) codecs.
        return lower.contains("video/mp4")
            && lower.contains("avc1")
            && lower.contains("mp4a")
            && item["url"] != nil
    }

    private func extractPlayerResponseJSON(from html: String) -> String? {
        let pattern = #"ytInitialPlayerResponse\s*=\s*(\{.*?\});"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let jsonRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[jsonRange])
    }

    private func iosUserAgent(countryCode: String) -> String {
        "com.google.ios.youtube/\(iosClientVersion)(\(iosDeviceModel); U; CPU iOS \(iosUserAgentVersion) like Mac OS X; \(countryCode))"
    }

    private func streamHeaders(videoId: String, userAgent: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/watch?v=\(videoId)",
            "Accept-Language": "en-US,en;q=0.9"
        ]

        // Prevent consent gating on some networks/regions.
        headers["Cookie"] = "CONSENT=YES+1"

        return headers
    }
}

private extension YouTubePlaybackService {
    func logStreamingDataIfNeeded(root: [String: Any], source: String) {
#if DEBUG
        guard let streamingData = root["streamingData"] as? [String: Any] else {
            print("[YouTubePlaybackService] \(source): no streamingData")
            return
        }

        if let hls = streamingData["hlsManifestUrl"] as? String {
            print("[YouTubePlaybackService] \(source): hlsManifestUrl = \(hls)")
        }
        if let dash = streamingData["dashManifestUrl"] as? String {
            print("[YouTubePlaybackService] \(source): dashManifestUrl = \(dash)")
        }

        if let formats = streamingData["formats"] as? [[String: Any]] {
            for (idx, item) in formats.enumerated() {
                let itag = item["itag"] as? Int ?? -1
                let mime = item["mimeType"] as? String ?? "unknown"
                let url = item["url"] as? String ?? "no-url"
                let cipher = item["signatureCipher"] as? String ?? item["cipher"] as? String ?? "no-cipher"
                print("[YouTubePlaybackService] \(source): formats[\(idx)] itag=\(itag) mime=\(mime) url=\(url) cipher=\(cipher)")
            }
        }

        if let adaptive = streamingData["adaptiveFormats"] as? [[String: Any]] {
            for (idx, item) in adaptive.enumerated() {
                let itag = item["itag"] as? Int ?? -1
                let mime = item["mimeType"] as? String ?? "unknown"
                let url = item["url"] as? String ?? "no-url"
                let cipher = item["signatureCipher"] as? String ?? item["cipher"] as? String ?? "no-cipher"
                print("[YouTubePlaybackService] \(source): adaptive[\(idx)] itag=\(itag) mime=\(mime) url=\(url) cipher=\(cipher)")
            }
        }
#endif
    }
}
