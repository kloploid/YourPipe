import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var selectedTab: AppTab = .newVideos

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    NewVideosView()
                        .tabItem {
                            Label("Новые", systemImage: "play.rectangle.fill")
                        }
                        .tag(AppTab.newVideos)

                    SubscriptionsView()
                        .tabItem {
                            Label("Подписки", systemImage: "person.2.fill")
                        }
                        .tag(AppTab.subscriptions)

                    SearchView()
                        .tabItem {
                            Label("Поиск", systemImage: "magnifyingglass")
                        }
                        .tag(AppTab.search)

                    SettingsView()
                        .tabItem {
                            Label("Настройки", systemImage: "gearshape.fill")
                        }
                        .tag(AppTab.settings)
                }
                .tint(.orange)

                if playback.hasActivePlayback && playback.presentation == nil {
                    MiniPlayerBar()
                        .padding(.bottom, proxy.safeAreaInsets.bottom + 49)
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .fullScreenCover(item: $playback.presentation) { presentation in
            VideoPlaybackScreen(
                videoId: presentation.videoId,
                initialTitle: presentation.title,
                initialMetaLine: presentation.metaLine,
                initialChannelName: presentation.channelName,
                initialChannelAvatarURL: presentation.channelAvatarURL,
                initialThumbnailURL: presentation.thumbnailURL,
                initialChannelId: presentation.channelId
            )
        }
    }
}

private enum AppTab {
    case newVideos
    case subscriptions
    case search
    case settings
}

private struct MiniPlayerBar: View {
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    playback.presentCurrent()
                } label: {
                    if let player = playback.player {
                        PlayerSurfaceView(player: player) { layer in
                            playback.attachPlayerLayer(layer)
                        }
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.gray.opacity(0.2))
                            .frame(width: 96, height: 54)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .buttonStyle(.plain)

                Button {
                    playback.presentCurrent()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playback.title ?? "Без названия")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(playback.channelName ?? "Канал")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }

                Button {
                    playback.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }
}

private struct NewVideosView: View {
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @StateObject private var viewModel = NewVideosViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if subscriptions.items.isEmpty {
                    SearchPlaceholderView(
                        title: "Нет подписок",
                        systemImage: "person.crop.square.badge.plus",
                        message: "Подпишитесь на каналы в поиске, чтобы видеть новые видео."
                    )
                } else if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView("Обновляем...")
                } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                    SearchPlaceholderView(
                        title: "Не удалось загрузить",
                        systemImage: "exclamationmark.triangle",
                        message: error
                    )
                } else {
                    List {
                        ForEach(viewModel.items) { item in
                            Button {
                                playback.present(
                                    videoId: item.id,
                                    title: item.title,
                                    metaLine: item.metaLine,
                                    channelName: item.channelName,
                                    channelAvatarURL: nil,
                                    thumbnailURL: item.thumbnailURL,
                                    channelId: item.channelId
                                )
                            } label: {
                                FeedVideoRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                viewModel.loadNextPageIfNeeded(currentItem: item)
                            }
                            .listRowSeparator(.hidden)
                        }

                        if viewModel.isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await viewModel.refresh(subscriptions: subscriptions.items)
                    }
                }
            }
            .navigationTitle("Новые видео")
            .task {
                await viewModel.refresh(subscriptions: subscriptions.items)
            }
            .onChange(of: subscriptions.items) { _ in
                Task { await viewModel.refresh(subscriptions: subscriptions.items) }
            }
        }
    }
}

private struct SubscriptionsView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore

    var body: some View {
        NavigationStack {
            Group {
                if subscriptions.items.isEmpty {
                    SearchPlaceholderView(
                        title: "Нет подписок",
                        systemImage: "person.crop.square.badge.plus",
                        message: "Подписки сохраняются локально. Добавьте каналы через поиск."
                    )
                } else {
                    List {
                        ForEach(subscriptions.items) { channel in
                            HStack(spacing: 12) {
                                SubscriptionAvatarView(
                                    avatarURL: channel.thumbnailURL,
                                    fallbackText: String(channel.title.prefix(1))
                                )
                                .frame(width: 44, height: 44)

                                Text(channel.title)
                                    .font(.headline)
                                Spacer()

                                Button("Отписаться") {
                                    subscriptions.unsubscribe(channel.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Подписки")
        }
    }
}

private struct SearchView: View {
    @EnvironmentObject private var playback: PlaybackController
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView("Ищем...")
                } else if viewModel.hasSearched && viewModel.items.isEmpty {
                    SearchPlaceholderView(
                        title: "Ничего не найдено",
                        systemImage: "magnifyingglass",
                        message: "Попробуйте другой запрос или фильтр."
                    )
                } else if !viewModel.hasSearched {
                    SearchPlaceholderView(
                        title: "Поиск YouTube",
                        systemImage: "play.rectangle",
                        message: "Введите запрос и нажмите поиск."
                    )
                } else {
                    List {
                        ForEach(viewModel.items) { item in
                            SearchResultRow(item: item)
                                .onAppear {
                                    viewModel.loadNextPageIfNeeded(currentItem: item)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard item.type == .video,
                                          let videoId = item.videoId else {
                                        return
                                    }
                                    playback.present(
                                        videoId: videoId,
                                        title: item.title,
                                        metaLine: item.metaLine,
                                        channelName: item.channelName,
                                        channelAvatarURL: item.channelAvatarURL,
                                        thumbnailURL: item.thumbnailURL,
                                        channelId: item.channelId
                                    )
                                }
                        }

                        if viewModel.isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Поиск")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Фильтр", selection: $viewModel.selectedFilter) {
                            ForEach(YouTubeSearchFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                    } label: {
                        Label("Фильтр", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .searchable(text: $viewModel.query, prompt: "Найти видео или канал")
            .onSubmit(of: .search) {
                Task { await viewModel.search() }
            }
            .onChange(of: viewModel.selectedFilter) { _ in
                viewModel.reloadForFilterChangeIfNeeded()
            }
            .alert("Ошибка", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { show in
                    if !show {
                        viewModel.errorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    viewModel.errorMessage = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "Неизвестная ошибка")
            }
        }
    }
}

private struct SearchPlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct SearchResultRow: View {
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
                            Image(systemName: iconName)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 112, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch item.type {
        case .video: return "play.rectangle.fill"
        case .channel: return "person.crop.square.fill"
        case .playlist: return "text.badge.plus"
        }
    }
}

private struct SubscriptionAvatarView: View {
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

private struct FeedVideoRow: View {
    let item: FeedVideoItem

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
            .frame(width: 112, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.channelName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let meta = item.metaLine {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsView: View {
    @State private var autoplayEnabled: Bool = true
    @State private var highQualityOnlyOnWiFi: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Плеер") {
                    Toggle("Автовоспроизведение", isOn: $autoplayEnabled)
                    Toggle("Высокое качество только по Wi-Fi", isOn: $highQualityOnlyOnWiFi)
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: "0.1 MVP")
                    LabeledContent("Телеметрия", value: "Отключена")
                }
            }
            .navigationTitle("Настройки")
        }
    }
}

#Preview("Tabs") {
    ContentView()
        .environmentObject(PlaybackController())
        .environmentObject(SubscriptionStore())
}

#Preview("New Videos") {
    NewVideosView()
}

#Preview("Subscriptions") {
    SubscriptionsView()
}

#Preview("Search") {
    SearchView()
        .environmentObject(PlaybackController())
        .environmentObject(SubscriptionStore())
}

#Preview("Settings") {
    SettingsView()
}
