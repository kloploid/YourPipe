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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .fill(.black)

                    if let player = playback.player {
                        PlayerSurfaceView(player: player) { layer in
                            playback.attachPlayerLayer(layer)
                        }
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
                        Text(playback.title ?? initialTitle)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.leading)

                        if let meta = initialMetaLine, !meta.isEmpty {
                            Text(meta)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        HStack(spacing: 12) {
                            ChannelAvatarView(
                                avatarURL: playback.channelAvatarURL ?? initialChannelAvatarURL,
                                fallbackText: String((playback.channelName ?? initialChannelName ?? "?").prefix(1))
                            )
                            .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(playback.channelName ?? initialChannelName ?? "Канал")
                                    .font(.headline)
                                Text("Открыто из поиска")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            if let channelId = playback.channelId ?? initialChannelId {
                                Button {
                                    subscriptions.toggle(ChannelSubscription(
                                        id: channelId,
                                        title: playback.channelName ?? initialChannelName ?? "Канал",
                                        thumbnailURL: playback.channelAvatarURL ?? initialChannelAvatarURL
                                    ))
                                } label: {
                                    Text(subscriptions.isSubscribed(channelId) ? "Вы подписаны" : "Подписаться")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if let error = playback.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
            }
            .background(Color(.systemBackground))
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
            }
        }
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
