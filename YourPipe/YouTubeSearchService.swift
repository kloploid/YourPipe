import Foundation

actor YouTubeSearchService {
    static let shared = YouTubeSearchService()

    private let session: URLSession
    private var validatedConfig: WebConfig?

    private let fallbackKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private let fallbackClientVersion = "2.20220809.02.00"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(
        query: String,
        filter: YouTubeSearchFilter,
        continuationToken: String? = nil,
        locale: Locale = .current
    ) async throws -> YouTubeSearchPage {
        let primaryConfig = try await loadWebConfig()
        do {
            return try await performSearch(
                query: query,
                filter: filter,
                continuationToken: continuationToken,
                locale: locale,
                config: primaryConfig
            )
        } catch SearchError.httpStatus(let code, let body) where code == 400 {
            let normalized = body.lowercased()
            if normalized.contains("invalid argument") {
                let fallback = WebConfig(key: fallbackKey, clientVersion: fallbackClientVersion)
                self.validatedConfig = fallback
                return try await performSearch(
                    query: query,
                    filter: filter,
                    continuationToken: continuationToken,
                    locale: locale,
                    config: fallback
                )
            }
            throw SearchError.httpStatus(code, body)
        }
    }

    func fetchChannelVideos(
        channelId: String,
        limit: Int = 20,
        locale: Locale = .current
    ) async throws -> [YouTubeChannelVideo] {
        let page = try await fetchChannelVideosPage(
            channelId: channelId,
            continuationToken: nil,
            limit: limit,
            locale: locale
        )
        return page.items
    }

    func fetchChannelVideosPage(
        channelId: String,
        continuationToken: String?,
        limit: Int = 20,
        locale: Locale = .current
    ) async throws -> YouTubeChannelVideosPage {
        let config = try await loadWebConfig()

        if let continuationToken {
            if let json = try await requestBrowseContinuation(
                continuationToken: continuationToken,
                locale: locale,
                config: config
            ) {
                let videos = parseBrowseVideos(json, limit: limit)
                let nextToken = findContinuationToken(in: json)
                return YouTubeChannelVideosPage(items: videos, continuationToken: nextToken)
            }
            return YouTubeChannelVideosPage(items: [], continuationToken: nil)
        }

        if let json = try await requestBrowse(
            channelId: channelId,
            params: "EgZ2aWRlb3PyBgQKAjoA",
            locale: locale,
            config: config
        ) {
            let videos = parseBrowseVideos(json, limit: limit)
            let nextToken = findContinuationToken(in: json)
            if !videos.isEmpty || nextToken != nil {
                return YouTubeChannelVideosPage(items: videos, continuationToken: nextToken)
            }
        }

        if let json = try await requestBrowse(
            channelId: channelId,
            params: nil,
            locale: locale,
            config: config
        ) {
            let videos = parseBrowseVideos(json, limit: limit)
            let nextToken = findContinuationToken(in: json)
            return YouTubeChannelVideosPage(items: videos, continuationToken: nextToken)
        }

        return YouTubeChannelVideosPage(items: [], continuationToken: nil)
    }

    private func performSearch(
        query: String,
        filter: YouTubeSearchFilter,
        continuationToken: String?,
        locale: Locale,
        config: WebConfig
    ) async throws -> YouTubeSearchPage {

        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.key),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]

        guard let url = components.url else {
            throw SearchError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(config.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CONSENT=PENDING+527", forHTTPHeaderField: "Cookie")

        var payload: [String: Any] = [
            "context": makeContext(clientVersion: config.clientVersion, locale: locale)
        ]

        if let continuationToken {
            payload["continuation"] = continuationToken
        } else {
            payload["query"] = query
            if let searchParameter = filter.searchParameter {
                payload["params"] = searchParameter
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SearchError.httpStatus(httpResponse.statusCode, body)
        }

        let rawJSON = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = rawJSON as? [String: Any] else {
            throw SearchError.invalidJSON
        }

        if continuationToken == nil {
            return parseInitialPage(root: root)
        } else {
            return parseContinuationPage(root: root)
        }
    }

    private func requestBrowse(
        channelId: String,
        params: String?,
        locale: Locale,
        config: WebConfig
    ) async throws -> [String: Any]? {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/browse")!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.key),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]

        guard let url = components.url else {
            throw SearchError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(config.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CONSENT=PENDING+527", forHTTPHeaderField: "Cookie")

        var body: [String: Any] = [
            "context": makeContext(clientVersion: config.clientVersion, locale: locale),
            "browseId": channelId
        ]
        if let params {
            body["params"] = params
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let rawJSON = try JSONSerialization.jsonObject(with: data, options: [])
        return rawJSON as? [String: Any]
    }

    private func requestBrowseContinuation(
        continuationToken: String,
        locale: Locale,
        config: WebConfig
    ) async throws -> [String: Any]? {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/browse")!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.key),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]

        guard let url = components.url else {
            throw SearchError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(config.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CONSENT=PENDING+527", forHTTPHeaderField: "Cookie")

        let body: [String: Any] = [
            "context": makeContext(clientVersion: config.clientVersion, locale: locale),
            "continuation": continuationToken
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let rawJSON = try JSONSerialization.jsonObject(with: data, options: [])
        return rawJSON as? [String: Any]
    }
}

private extension YouTubeSearchService {
    struct WebConfig {
        let key: String
        let clientVersion: String
    }

    enum SearchError: LocalizedError {
        case badURL
        case invalidResponse
        case invalidJSON
        case httpStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "Не удалось сформировать URL поиска."
            case .invalidResponse:
                return "Сервер вернул некорректный ответ."
            case .invalidJSON:
                return "Не удалось прочитать ответ YouTube."
            case .httpStatus(let code, let body):
                let snippet = body.replacingOccurrences(of: "\n", with: " ").prefix(140)
                if snippet.isEmpty {
                    return "Ошибка сети YouTube: HTTP \(code)."
                }
                return "Ошибка сети YouTube: HTTP \(code). \(snippet)"
            }
        }
    }

    func loadWebConfig() async throws -> WebConfig {
        if let validatedConfig {
            return validatedConfig
        }

        let extractedConfig = await extractConfigFromWeb()
        if let extractedConfig, await isValid(config: extractedConfig) {
            self.validatedConfig = extractedConfig
            return extractedConfig
        }

        let fallback = WebConfig(key: fallbackKey, clientVersion: fallbackClientVersion)
        self.validatedConfig = fallback
        return fallback
    }

    func extractConfigFromWeb() async -> WebConfig? {
        do {
            let (data, _) = try await session.data(from: URL(string: "https://www.youtube.com/sw.js")!)
            let text = String(data: data, encoding: .utf8) ?? ""

            let extractedKey = match(
                text,
                patterns: [
                    #"INNERTUBE_API_KEY":"([0-9A-Za-z_-]{20,})""#,
                    #"innertubeApiKey":"([0-9A-Za-z_-]{20,})""#,
                    #"INNERTUBE_API_KEY\\":\\"([0-9A-Za-z_-]{20,})"#,
                    #"innertubeApiKey\\":\\"([0-9A-Za-z_-]{20,})"#
                ]
            )
            let extractedVersion = match(
                text,
                patterns: [
                    #"INNERTUBE_CONTEXT_CLIENT_VERSION":"([0-9\.]+?)""#,
                    #"innertube_context_client_version":"([0-9\.]+?)""#,
                    #"INNERTUBE_CONTEXT_CLIENT_VERSION\\":\\"([0-9\.]+?)"#,
                    #"innertube_context_client_version\\":\\"([0-9\.]+?)"#,
                    #"client\.version=([0-9\.]+)"#
                ]
            )

            guard let extractedKey, let extractedVersion else {
                return nil
            }
            return WebConfig(key: extractedKey, clientVersion: extractedVersion)
        } catch {
            return nil
        }
    }

    func isValid(config: WebConfig) async -> Bool {
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/guide")!
        components.queryItems = [
            URLQueryItem(name: "key", value: config.key),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(config.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        request.setValue("CONSENT=PENDING+527", forHTTPHeaderField: "Cookie")

        let payload: [String: Any] = [
            "context": [
                "client": [
                    "hl": "en-US",
                    "gl": "US",
                    "clientName": "WEB",
                    "clientVersion": config.clientVersion
                ],
                "user": [
                    "lockedSafetyMode": false
                ]
            ],
            "fetchLiveState": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            guard (200...299).contains(httpResponse.statusCode) else { return false }
            return data.count > 2048
        } catch {
            return false
        }
    }

    func match(_ text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..., in: text)
                if let result = regex.firstMatch(in: text, options: [], range: range),
                   result.numberOfRanges > 1,
                   let captureRange = Range(result.range(at: 1), in: text) {
                    return String(text[captureRange])
                }
            }
        }
        return nil
    }

    func makeContext(clientVersion: String, locale: Locale) -> [String: Any] {
        let rawRegion = locale.region?.identifier.uppercased() ?? "US"
        let region = rawRegion.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil
            ? rawRegion
            : "US"
        // Keep stable language like Android extractor default to avoid invalid combos like en-EE.
        let hl = "en-GB"

        return [
            "client": [
                "hl": hl,
                "gl": region,
                "clientName": "WEB",
                "clientVersion": clientVersion,
                "originalUrl": "https://www.youtube.com",
                "platform": "DESKTOP"
            ],
            "request": [
                "internalExperimentFlags": [],
                "useSsl": true
            ],
            "user": [
                "lockedSafetyMode": false
            ]
        ]
    }

    func parseInitialPage(root: [String: Any]) -> YouTubeSearchPage {
        let sections = ((((root["contents"] as? [String: Any])?["twoColumnSearchResultsRenderer"] as? [String: Any])?["primaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        let items = parseItems(from: sections)
        let token = extractContinuationToken(from: sections)
        return YouTubeSearchPage(items: items, continuationToken: token)
    }

    func parseContinuationPage(root: [String: Any]) -> YouTubeSearchPage {
        let continuationItems = ((((root["onResponseReceivedCommands"] as? [[String: Any]])?.first)?["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"] as? [[String: Any]] ?? [])
        let items = parseItems(from: continuationItems)
        let token = extractContinuationToken(from: continuationItems)
        return YouTubeSearchPage(items: items, continuationToken: token)
    }

    func parseItems(from sections: [[String: Any]]) -> [YouTubeSearchItem] {
        var result: [YouTubeSearchItem] = []

        for section in sections {
            guard let itemSection = section["itemSectionRenderer"] as? [String: Any],
                  let contents = itemSection["contents"] as? [[String: Any]] else {
                continue
            }
            for content in contents {
                if let item = parseVideo(from: content) ?? parseChannel(from: content) ?? parsePlaylist(from: content) {
                    result.append(item)
                }
            }
        }

        return result
    }

    func parseVideo(from content: [String: Any]) -> YouTubeSearchItem? {
        guard let renderer = content["videoRenderer"] as? [String: Any],
              let id = renderer["videoId"] as? String else {
            return nil
        }

        let title = text(from: renderer["title"]) ?? "Без названия"
        let channelName = text(from: renderer["ownerText"]) ?? text(from: renderer["longBylineText"]) ?? "YouTube"
        let channelId = channelId(from: renderer["ownerText"]) ?? channelId(from: renderer["longBylineText"])
        let subtitle = channelName
        let viewCount = text(from: renderer["viewCountText"])
        let publishTime = text(from: renderer["publishedTimeText"])
        let metaLine = [viewCount, publishTime].compactMap { $0 }.joined(separator: " • ")
        let thumbnail = thumbnailURL(from: renderer["thumbnail"])
        let channelThumbnailRenderers = renderer["channelThumbnailSupportedRenderers"] as? [String: Any]
        let channelThumbnailLinkRenderer = channelThumbnailRenderers?["channelThumbnailWithLinkRenderer"] as? [String: Any]
        let channelAvatar = thumbnailURL(from: channelThumbnailLinkRenderer?["thumbnail"])
        return YouTubeSearchItem(
            id: "video:\(id)",
            type: .video,
            title: title,
            subtitle: subtitle,
            thumbnailURL: thumbnail,
            videoId: id,
            channelId: channelId,
            channelName: channelName,
            channelAvatarURL: channelAvatar,
            metaLine: metaLine.isEmpty ? nil : metaLine
        )
    }

    func parseChannel(from content: [String: Any]) -> YouTubeSearchItem? {
        guard let renderer = content["channelRenderer"] as? [String: Any],
              let id = renderer["channelId"] as? String else {
            return nil
        }

        let title = text(from: renderer["title"]) ?? "Канал"
        let subtitle = text(from: renderer["descriptionSnippet"]) ?? "Канал"
        let thumbnail = thumbnailURL(from: renderer["thumbnail"])
        return YouTubeSearchItem(
            id: "channel:\(id)",
            type: .channel,
            title: title,
            subtitle: subtitle,
            thumbnailURL: thumbnail,
            videoId: nil,
            channelId: id,
            channelName: title,
            channelAvatarURL: thumbnail,
            metaLine: nil
        )
    }

    func parsePlaylist(from content: [String: Any]) -> YouTubeSearchItem? {
        guard let renderer = content["playlistRenderer"] as? [String: Any],
              let id = renderer["playlistId"] as? String else {
            return nil
        }

        let title = text(from: renderer["title"]) ?? "Плейлист"
        let subtitle = text(from: renderer["longBylineText"]) ?? text(from: renderer["shortBylineText"]) ?? "Плейлист"
        let thumbnail = thumbnailURL(from: renderer["thumbnails"] ?? renderer["thumbnail"])
        return YouTubeSearchItem(
            id: "playlist:\(id)",
            type: .playlist,
            title: title,
            subtitle: subtitle,
            thumbnailURL: thumbnail,
            videoId: nil,
            channelId: nil,
            channelName: nil,
            channelAvatarURL: nil,
            metaLine: nil
        )
    }

    func text(from value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let simpleText = object["simpleText"] as? String {
            return simpleText
        }
        if let runs = object["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    func thumbnailURL(from value: Any?) -> URL? {
        guard let object = value as? [String: Any] else { return nil }

        if let thumbnails = object["thumbnails"] as? [[String: Any]],
           let rawURL = (thumbnails.last?["url"] as? String) ?? (thumbnails.first?["url"] as? String) {
            return URL(string: rawURL)
        }

        if let items = object["items"] as? [[String: Any]],
           let firstItem = items.first,
           let thumbnails = firstItem["thumbnails"] as? [[String: Any]],
           let rawURL = (thumbnails.last?["url"] as? String) ?? (thumbnails.first?["url"] as? String) {
            return URL(string: rawURL)
        }

        return nil
    }

    func channelId(from value: Any?) -> String? {
        guard let object = value as? [String: Any],
              let runs = object["runs"] as? [[String: Any]] else {
            return nil
        }

        for run in runs {
            guard let endpoint = run["navigationEndpoint"] as? [String: Any],
                  let browseEndpoint = endpoint["browseEndpoint"] as? [String: Any],
                  let browseId = browseEndpoint["browseId"] as? String else {
                continue
            }
            return browseId
        }
        return nil
    }

    func parseBrowseVideos(_ json: [String: Any], limit: Int) -> [YouTubeChannelVideo] {
        var collected: [YouTubeChannelVideo] = []
        collectVideoRenderers(in: json, output: &collected)
        return Array(collected.prefix(limit))
    }

    func collectVideoRenderers(in value: Any, output: inout [YouTubeChannelVideo]) {
        if let dict = value as? [String: Any] {
            if let video = dict["videoRenderer"] as? [String: Any],
               let id = video["videoId"] as? String {
                let title = text(from: video["title"]) ?? "Без названия"
                let channelName = text(from: video["ownerText"]) ?? "YouTube"
                let channelId = channelId(from: video["ownerText"])
                let thumb = thumbnailURL(from: video["thumbnail"])
                let published = text(from: video["publishedTimeText"])
                let viewCount = text(from: video["viewCountText"])
                let isLive = isLiveVideo(video)
                output.append(YouTubeChannelVideo(
                    id: id,
                    title: title,
                    channelName: channelName,
                    channelId: channelId,
                    thumbnailURL: thumb,
                    publishedText: published,
                    viewCountText: viewCount,
                    isLive: isLive
                ))
            }
            if let gridVideo = dict["gridVideoRenderer"] as? [String: Any],
               let id = gridVideo["videoId"] as? String {
                let title = text(from: gridVideo["title"]) ?? "Без названия"
                let channelName = text(from: gridVideo["shortBylineText"])
                    ?? text(from: gridVideo["ownerText"])
                    ?? "YouTube"
                let channelId = channelId(from: gridVideo["shortBylineText"])
                    ?? channelId(from: gridVideo["ownerText"])
                let thumb = thumbnailURL(from: gridVideo["thumbnail"])
                let published = text(from: gridVideo["publishedTimeText"])
                let viewCount = text(from: gridVideo["viewCountText"])
                    ?? text(from: gridVideo["shortViewCountText"])
                let isLive = isLiveVideo(gridVideo)
                output.append(YouTubeChannelVideo(
                    id: id,
                    title: title,
                    channelName: channelName,
                    channelId: channelId,
                    thumbnailURL: thumb,
                    publishedText: published,
                    viewCountText: viewCount,
                    isLive: isLive
                ))
            }

            for child in dict.values {
                collectVideoRenderers(in: child, output: &output)
            }
            return
        }

        if let list = value as? [Any] {
            for child in list {
                collectVideoRenderers(in: child, output: &output)
            }
        }
    }

    func isLiveVideo(_ renderer: [String: Any]) -> Bool {
        if let badges = renderer["badges"] as? [[String: Any]] {
            for badge in badges {
                if let metadata = badge["metadataBadgeRenderer"] as? [String: Any],
                   let style = metadata["style"] as? String,
                   style.contains("LIVE") {
                    return true
                }
            }
        }

        if let overlays = renderer["thumbnailOverlays"] as? [[String: Any]] {
            for overlay in overlays {
                if let status = overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any],
                   let style = status["style"] as? String,
                   style.contains("LIVE") {
                    return true
                }
            }
        }

        return false
    }

    func findContinuationToken(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let continuationCommand = dict["continuationCommand"] as? [String: Any],
               let token = continuationCommand["token"] as? String {
                return token
            }
            for child in dict.values {
                if let token = findContinuationToken(in: child) {
                    return token
                }
            }
            return nil
        }

        if let list = value as? [Any] {
            for child in list {
                if let token = findContinuationToken(in: child) {
                    return token
                }
            }
        }
        return nil
    }

    func extractContinuationToken(from sections: [[String: Any]]) -> String? {
        for section in sections {
            if let continuationItemRenderer = section["continuationItemRenderer"] as? [String: Any],
               let endpoint = continuationItemRenderer["continuationEndpoint"] as? [String: Any],
               let command = endpoint["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String {
                return token
            }
        }
        return nil
    }
}
