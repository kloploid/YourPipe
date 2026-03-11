import Foundation

struct FeedVideoItem: Identifiable, Equatable {
    let id: String
    let title: String
    let channelName: String
    let channelId: String?
    let thumbnailURL: URL?
    let metaLine: String?
    let ageMinutes: Int?
    let isLive: Bool
}

@MainActor
final class NewVideosViewModel: ObservableObject {
    @Published var items: [FeedVideoItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isLoadingMore = false

    private let service: YouTubeSearchService
    private var channelStates: [String: ChannelFeedState] = [:]
    private var currentSubscriptions: [ChannelSubscription] = []

    init(service: YouTubeSearchService = .shared) {
        self.service = service
    }

    func refresh(subscriptions: [ChannelSubscription]) async {
        guard !subscriptions.isEmpty else {
            items = []
            errorMessage = nil
            channelStates = [:]
            currentSubscriptions = []
            return
        }

        isLoading = true
        errorMessage = nil
        currentSubscriptions = subscriptions
        channelStates = [:]

        var collected: [FeedVideoItem] = []

        do {
            try await withThrowingTaskGroup(of: ChannelFeedState.self) { group in
                for channel in subscriptions {
                    group.addTask {
                        let page = try await self.service.fetchChannelVideosPage(
                            channelId: channel.id,
                            continuationToken: nil,
                            limit: 8
                        )
                        let feedItems = page.items.map { video in
                            makeFeedItem(video: video, fallbackChannelId: channel.id)
                        }
                        return makeChannelState(
                            channelId: channel.id,
                            items: feedItems,
                            continuationToken: page.continuationToken
                        )
                    }
                }

                for try await state in group {
                    channelStates[state.channelId] = state
                }
            }

            for channel in subscriptions {
                collected.append(contentsOf: channelStates[channel.id]?.items ?? [])
            }
            items = sortFeedItems(collected)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadNextPageIfNeeded(currentItem: FeedVideoItem) {
        guard let last = items.last, last.id == currentItem.id else { return }
        guard !isLoading, !isLoadingMore else { return }
        guard channelStates.values.contains(where: { $0.continuationToken != nil }) else { return }

        Task {
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !currentSubscriptions.isEmpty else { return }
        isLoadingMore = true

        var newItemsByChannel: [String: [FeedVideoItem]] = [:]

        do {
            try await withThrowingTaskGroup(of: ChannelFeedState?.self) { group in
                for channel in currentSubscriptions {
                    guard let token = channelStates[channel.id]?.continuationToken else { continue }
                    group.addTask {
                        let page = try await self.service.fetchChannelVideosPage(
                            channelId: channel.id,
                            continuationToken: token,
                            limit: 8
                        )
                        let feedItems = page.items.map { video in
                            makeFeedItem(video: video, fallbackChannelId: channel.id)
                        }
                        return makeChannelState(
                            channelId: channel.id,
                            items: feedItems,
                            continuationToken: page.continuationToken
                        )
                    }
                }

                for try await state in group {
                    guard let state else { continue }
                    channelStates[state.channelId] = state
                    newItemsByChannel[state.channelId] = state.items
                }
            }

            var appended: [FeedVideoItem] = []
            for channel in currentSubscriptions {
                if let newItems = newItemsByChannel[channel.id] {
                    appended.append(contentsOf: newItems)
                }
            }
            if !appended.isEmpty {
                items.append(contentsOf: appended)
                items = sortFeedItems(items)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingMore = false
    }
}

private struct ChannelFeedState {
    let channelId: String
    let items: [FeedVideoItem]
    let continuationToken: String?
}

private func makeChannelState(
    channelId: String,
    items: [FeedVideoItem],
    continuationToken: String?
) -> ChannelFeedState {
    let next = items.isEmpty ? nil : continuationToken
    return ChannelFeedState(channelId: channelId, items: items, continuationToken: next)
}

private func makeFeedItem(video: YouTubeChannelVideo, fallbackChannelId: String) -> FeedVideoItem {
    let metaParts = [video.viewCountText, video.publishedText].compactMap { $0 }
    return FeedVideoItem(
        id: video.id,
        title: video.title,
        channelName: video.channelName,
        channelId: video.channelId ?? fallbackChannelId,
        thumbnailURL: video.thumbnailURL,
        metaLine: metaParts.isEmpty ? nil : metaParts.joined(separator: " • "),
        ageMinutes: parseAgeMinutes(video.publishedText),
        isLive: video.isLive
    )
}

private func sortFeedItems(_ items: [FeedVideoItem]) -> [FeedVideoItem] {
    var seen: Set<String> = []
    let unique = items.filter { item in
        if seen.contains(item.id) { return false }
        seen.insert(item.id)
        return true
    }

    return unique.sorted { lhs, rhs in
        if lhs.isLive != rhs.isLive {
            return lhs.isLive && !rhs.isLive
        }
        switch (lhs.ageMinutes, rhs.ageMinutes) {
        case let (l?, r?):
            if l != r { return l < r }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        return lhs.title < rhs.title
    }
}

private func parseAgeMinutes(_ text: String?) -> Int? {
    guard var raw = text?.lowercased() else { return nil }
    raw = raw.replacingOccurrences(of: "\u{00A0}", with: " ")

    if raw.contains("live") || raw.contains("стрим") || raw.contains("прямой эфир") {
        return 0
    }
    if raw.contains("just now") || raw.contains("moments ago") || raw.contains("только что") || raw.contains("сейчас") {
        return 0
    }
    if raw.contains("yesterday") || raw.contains("вчера") {
        return 24 * 60
    }

    let number = extractFirstInt(raw)

    if raw.contains("minute") || raw.contains("мин") {
        return number ?? 0
    }
    if raw.contains("hour") || raw.contains("час") {
        return (number ?? 0) * 60
    }
    if raw.contains("day") || raw.contains("дн") {
        return (number ?? 0) * 24 * 60
    }
    if raw.contains("week") || raw.contains("нед") {
        return (number ?? 0) * 7 * 24 * 60
    }
    if raw.contains("month") || raw.contains("мес") {
        return (number ?? 0) * 30 * 24 * 60
    }
    if raw.contains("year") || raw.contains("год") || raw.contains("лет") {
        return (number ?? 0) * 365 * 24 * 60
    }

    return nil
}

private func extractFirstInt(_ text: String) -> Int? {
    let digits = text.split { !$0.isNumber }
    return digits.first.flatMap { Int($0) }
}
