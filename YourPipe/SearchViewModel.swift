import Foundation
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedFilter: YouTubeSearchFilter = .all
    @Published var items: [YouTubeSearchItem] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var hasSearched: Bool = false

    private let service: YouTubeSearchService
    private var continuationToken: String?
    private var isLoadingMore = false

    init(service: YouTubeSearchService = .shared) {
        self.service = service
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        hasSearched = true
        continuationToken = nil

        do {
            let page = try await service.search(query: trimmed, filter: selectedFilter)
            items = page.items
            continuationToken = page.continuationToken
        } catch {
            items = []
            continuationToken = nil
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func reloadForFilterChangeIfNeeded() {
        guard hasSearched else { return }
        Task { await search() }
    }

    func loadNextPageIfNeeded(currentItem: YouTubeSearchItem) {
        guard let last = items.last, last.id == currentItem.id else { return }
        guard continuationToken != nil, !isLoading, !isLoadingMore else { return }

        Task {
            await loadNextPage()
        }
    }

    private func loadNextPage() async {
        guard let token = continuationToken else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoadingMore = true
        isLoading = true
        defer {
            isLoadingMore = false
            isLoading = false
        }

        do {
            let page = try await service.search(
                query: trimmed,
                filter: selectedFilter,
                continuationToken: token
            )
            items.append(contentsOf: page.items)
            continuationToken = page.continuationToken
        } catch {
            errorMessage = error.localizedDescription
            continuationToken = nil
        }
    }
}
