import Foundation

enum YouTubeSearchFilter: String, CaseIterable, Identifiable {
    case all
    case videos
    case channels
    case playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Все"
        case .videos: return "Видео"
        case .channels: return "Каналы"
        case .playlists: return "Плейлисты"
        }
    }

    var searchParameter: String? {
        switch self {
        case .all: return nil
        case .videos: return "EgIQAQ%3D%3D"
        case .channels: return "EgIQAg%3D%3D"
        case .playlists: return "EgIQAw%3D%3D"
        }
    }
}

enum YouTubeSearchItemType {
    case video
    case channel
    case playlist
}

struct YouTubeSearchItem: Identifiable, Equatable {
    let id: String
    let type: YouTubeSearchItemType
    let title: String
    let subtitle: String
    let thumbnailURL: URL?
    let videoId: String?
    let channelId: String?
    let channelName: String?
    let channelAvatarURL: URL?
    let metaLine: String?
}

struct YouTubeSearchPage {
    let items: [YouTubeSearchItem]
    let continuationToken: String?
}

struct YouTubeChannelVideosPage {
    let items: [YouTubeChannelVideo]
    let continuationToken: String?
}

struct YouTubeChannelVideo: Identifiable, Equatable {
    let id: String
    let title: String
    let channelName: String
    let channelId: String?
    let thumbnailURL: URL?
    let publishedText: String?
    let viewCountText: String?
    let isLive: Bool
}
