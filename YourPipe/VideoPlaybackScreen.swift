import SwiftUI
import AVKit

struct VideoPlaybackScreen: View {
    let videoId: String
    let initialTitle: String
    let initialMetaLine: String?
    let initialChannelName: String?
    let initialChannelAvatarURL: URL?
    let initialThumbnailURL: URL?
    let initialChannelId: String?

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSection: PlaybackSection = .description
    @StateObject private var details = VideoDetailsViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .fill(.black)

                    if let player = playback.player {
                        SystemPlayerView(player: player)
                    } else if playback.isLoading {
                        ProgressView("Загрузка видео...")
                            .tint(.white)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("Не удалось загрузить поток")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.white)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VideoHeaderView(
                            title: playback.title ?? initialTitle,
                            metaLine: playback.metaLine ?? initialMetaLine,
                            channelName: playback.channelName ?? initialChannelName,
                            channelAvatarURL: playback.channelAvatarURL ?? initialChannelAvatarURL,
                            sourceLabel: playback.activeSourceLabel,
                            channelId: playback.channelId ?? initialChannelId,
                            isSubscribed: { channelId in
                                subscriptions.isSubscribed(channelId)
                            },
                            toggleSubscription: { channelId in
                                subscriptions.toggle(ChannelSubscription(
                                    id: channelId,
                                    title: playback.channelName ?? initialChannelName ?? "Канал",
                                    thumbnailURL: playback.channelAvatarURL ?? initialChannelAvatarURL
                                ))
                            },
                            errorMessage: playback.errorMessage
                        )

                        Divider()

                        PlaybackSectionContent(
                            selection: selectedSection,
                            descriptionText: playback.descriptionText,
                            details: details,
                            onSelectRelated: { item in
                                guard item.type == .video,
                                      let videoId = item.videoId else {
                                    return
                                }
                                Task {
                                    await playback.play(
                                        videoId: videoId,
                                        fallbackTitle: item.title,
                                        fallbackMetaLine: item.metaLine,
                                        fallbackChannelName: item.channelName,
                                        fallbackChannelAvatarURL: item.channelAvatarURL,
                                        fallbackThumbnailURL: item.thumbnailURL,
                                        fallbackChannelId: item.channelId
                                    )
                                    await details.loadRelated(
                                        for: playback.title ?? item.title,
                                        excluding: playback.currentVideoId
                                    )
                                }
                            }
                        )
                    }
                    .padding()
                }
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom) {
                PlaybackBottomBar(selection: $selectedSection)
            }
            .navigationTitle("Видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                await playback.play(
                    videoId: videoId,
                    fallbackTitle: initialTitle,
                    fallbackMetaLine: initialMetaLine,
                    fallbackChannelName: initialChannelName,
                    fallbackChannelAvatarURL: initialChannelAvatarURL,
                    fallbackThumbnailURL: initialThumbnailURL,
                    fallbackChannelId: initialChannelId
                )
                await details.loadRelated(
                    for: playback.title ?? initialTitle,
                    excluding: playback.currentVideoId
                )
            }
            .onChange(of: playback.title) { newTitle in
                guard let newTitle, !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                Task {
                    await details.loadRelated(
                        for: newTitle,
                        excluding: playback.currentVideoId
                    )
                }
            }
        }
    }
}

private struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        // CRITICAL for the lock-screen Now Playing widget: AVPlayerViewController
        // defaults to overwriting MPNowPlayingInfoCenter.default().nowPlayingInfo
        // with minimal auto-generated metadata (no artwork, wrong command set).
        // That auto-overwrite is precisely what makes the widget render with
        // invisible transport icons — iOS draws the widget based on
        // AVPlayerViewController's skeletal info, ignoring our full setup in
        // PlaybackController. Turning this off lets our MPRemoteCommandCenter +
        // MPNowPlayingInfoCenter configuration own the widget end-to-end.
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

private enum PlaybackSection: String, CaseIterable, Identifiable {
    case description
    case comments
    case related

    var id: String { rawValue }

    var title: String {
        switch self {
        case .description: return "Описание"
        case .comments: return "Комментарии"
        case .related: return "Рекомендации"
        }
    }

    var systemImage: String {
        switch self {
        case .description: return "text.alignleft"
        case .comments: return "text.bubble"
        case .related: return "sparkles.tv"
        }
    }
}

@MainActor
private final class VideoDetailsViewModel: ObservableObject {
    @Published var related: [YouTubeSearchItem] = []
    @Published var isLoadingRelated = false
    @Published var relatedError: String?

    @Published var comments: [VideoComment] = []
    @Published var isLoadingComments = false
    @Published var commentsError: String?

    private let searchService: YouTubeSearchService
    private var lastRelatedKey: String?

    init(searchService: YouTubeSearchService = .shared) {
        self.searchService = searchService
    }

    func loadRelated(for query: String, excluding videoId: String?) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            related = []
            isLoadingRelated = false
            return
        }
        let key = "\(trimmed)|\(videoId ?? "")"
        guard lastRelatedKey != key else { return }
        lastRelatedKey = key

        isLoadingRelated = true
        relatedError = nil

        do {
            let page = try await searchService.search(query: trimmed, filter: .videos)
            related = page.items.filter { item in
                item.type == .video && item.videoId != videoId
            }
        } catch {
            related = []
            relatedError = error.localizedDescription
        }

        isLoadingRelated = false
    }
}

private struct VideoComment: Identifiable, Equatable {
    let id: String
    let author: String
    let text: String
    let likeCountText: String?
    let publishedText: String?
}

private struct VideoHeaderView: View {
    let title: String
    let metaLine: String?
    let channelName: String?
    let channelAvatarURL: URL?
    let sourceLabel: String?
    let channelId: String?
    let isSubscribed: (String) -> Bool
    let toggleSubscription: (String) -> Void
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.leading)

            if let meta = metaLine, !meta.isEmpty {
                Text(meta)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let sourceLabel, !sourceLabel.isEmpty {
                Text("Источник: \(sourceLabel)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                ChannelAvatarView(
                    avatarURL: channelAvatarURL,
                    fallbackText: String((channelName ?? "?").prefix(1))
                )
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channelName ?? "Канал")
                        .font(.headline)
                    Text("Открыто из поиска")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if let channelId {
                    Button {
                        toggleSubscription(channelId)
                    } label: {
                        Text(isSubscribed(channelId) ? "Вы подписаны" : "Подписаться")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct PlaybackSectionContent: View {
    let selection: PlaybackSection
    let descriptionText: String?
    @ObservedObject var details: VideoDetailsViewModel
    let onSelectRelated: (YouTubeSearchItem) -> Void

    var body: some View {
        switch selection {
        case .description:
            DescriptionSection(text: descriptionText)
        case .comments:
            CommentsSection(details: details)
        case .related:
            RelatedSection(details: details, onSelect: onSelectRelated)
        }
    }
}

private struct DescriptionSection: View {
    let text: String?

    var body: some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SectionPlaceholderView(
                title: "Описание недоступно",
                systemImage: "text.alignleft",
                message: "У этого видео нет описания или оно пока не загружено."
            )
        }
    }
}

private struct CommentsSection: View {
    @ObservedObject var details: VideoDetailsViewModel

    var body: some View {
        if details.isLoadingComments {
            ProgressView("Загрузка комментариев...")
        } else if let error = details.commentsError {
            SectionPlaceholderView(
                title: "Не удалось загрузить",
                systemImage: "exclamationmark.triangle",
                message: error
            )
        } else if details.comments.isEmpty {
            SectionPlaceholderView(
                title: "Комментарии пока недоступны",
                systemImage: "text.bubble",
                message: "Добавим загрузку комментариев в следующем шаге."
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(details.comments) { comment in
                    CommentRow(comment: comment)
                }
            }
        }
    }
}

private struct RelatedSection: View {
    @ObservedObject var details: VideoDetailsViewModel
    let onSelect: (YouTubeSearchItem) -> Void

    var body: some View {
        if details.isLoadingRelated {
            ProgressView("Подбираем рекомендации...")
        } else if let error = details.relatedError {
            SectionPlaceholderView(
                title: "Не удалось загрузить",
                systemImage: "exclamationmark.triangle",
                message: error
            )
        } else if details.related.isEmpty {
            SectionPlaceholderView(
                title: "Нет рекомендаций",
                systemImage: "sparkles.tv",
                message: "Попробуйте обновить или выберите другое видео."
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(details.related) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        RelatedVideoRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct PlaybackBottomBar: View {
    @Binding var selection: PlaybackSection

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PlaybackSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                        Text(section.title)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .foregroundStyle(selection == section ? .orange : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
    }
}

private struct RelatedVideoRow: View {
    let item: YouTubeSearchItem

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnailURL = item.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.gray.opacity(0.2))
                            .overlay(ProgressView())
                    }
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.gray.opacity(0.2))
                        .overlay {
                            Image(systemName: "play.rectangle.fill")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let channel = item.channelName {
                    Text(channel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let meta = item.metaLine, !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: VideoComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.gray.opacity(0.2))
                    .frame(width: 28, height: 28)
                Text(comment.author)
                    .font(.subheadline.weight(.semibold))
                if let published = comment.publishedText {
                    Text(published)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(comment.text)
                .font(.body)
            if let likes = comment.likeCountText {
                Text(likes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SectionPlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }
}

private struct ChannelAvatarView: View {
    let avatarURL: URL?
    let fallbackText: String

    var body: some View {
        Group {
            if let avatarURL {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(.gray.opacity(0.2))
                }
            } else {
                Circle()
                    .fill(.orange.opacity(0.2))
                    .overlay {
                        Text(fallbackText)
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
            }
        }
        .clipShape(Circle())
    }
}
