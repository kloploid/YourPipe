import Foundation

struct ChannelSubscription: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var thumbnailURL: URL?
}

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var items: [ChannelSubscription] = []

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("YourPipe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("subscriptions.json")
        load()
    }

    func isSubscribed(_ channelId: String) -> Bool {
        items.contains { $0.id == channelId }
    }

    func subscribe(_ channel: ChannelSubscription) {
        guard !isSubscribed(channel.id) else { return }
        items.append(channel)
        save()
    }

    func unsubscribe(_ channelId: String) {
        items.removeAll { $0.id == channelId }
        save()
    }

    func toggle(_ channel: ChannelSubscription) {
        if isSubscribed(channel.id) {
            unsubscribe(channel.id)
        } else {
            subscribe(channel)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        items = (try? JSONDecoder().decode([ChannelSubscription].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
