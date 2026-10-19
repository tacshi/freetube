import SwiftUI
import SwiftData

/// **Home** tab. The bottom bar's primary tab; combines three things in one screen:
///   1. A search field (native `.searchable` on iOS/iPadOS, inline capsule on Mac).
///   2. A "Recent searches" section showing the last 10 queries with a Clear button.
///   3. The home video feed below.
///
/// **Flip between modes** by inspecting `searchModel.query` and `searchModel.results`:
///   - Empty query + no results → render the recents + home feed list.
///   - Non-empty query or any results / suggestions / spinner → render `SearchContent`.
/// Clearing the search field automatically returns to the recents+feed view.
///
/// **Mac runtime** gets a custom inline search field above the content via
/// `MacInlineSearchField`, because SwiftUI's `.searchable` collapses to a trailing toolbar
/// button on Designed-for-iPad-on-Mac and real Catalyst, which is awkward at desktop widths.
/// iOS/iPadOS uses the native `.searchable` modifier as usual.
@available(iOS 17.0, *)
struct HomeScreen: View {
    @State private var model = HomeViewModel()
    @State private var searchModel = SearchViewModel()
    @Environment(PlayerStateManager.self) private var player
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Recent search queries — same store the previous Search tab used. Stays here so the
    /// host can do the upsert in `runSearch` (the field's submit fires on this view).
    @Query(sort: \SearchHistoryEntry.searchedAt, order: .reverse) private var history: [SearchHistoryEntry]

    private var isSearchActive: Bool {
        !searchModel.query.trimmingCharacters(in: .whitespaces).isEmpty
            || searchModel.results != nil
            || !searchModel.suggestions.isEmpty
            || searchModel.isLoading
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if MacIntegration.isRunningOnMac {
                    MacInlineSearchField(query: $searchModel.query) {
                        Task { await runSearch() }
                    }
                }

                Group {
                    if isSearchActive {
                        SearchContent(model: searchModel) {
                            Task { await runSearch() }
                        }
                    } else {
                        homeFeed
                    }
                }
            }
            // No title: the tab bar already says Home. Inline mode keeps the bar compact (it
            // still hosts the search field) instead of reserving large-title space.
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ConditionalSearchable(
                text: $searchModel.query,
                enabled: !MacIntegration.isRunningOnMac,
                prompt: "Search YouTube"
            ))
            .onSubmit(of: .search) {
                Task { await runSearch() }
            }
            // When the user clears the search field (binding flips to empty), drop the
            // previous results + suggestions so the home feed re-renders cleanly.
            .onChange(of: searchModel.query) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchModel.clearResults()
                }
            }
            .refreshable {
                if isSearchActive {
                    await searchModel.submit()
                } else {
                    await model.refresh()
                }
            }
            .task {
                if model.sections.isEmpty { await model.load() }
            }
            // Reload the home feed whenever the auth status flips. After sign-in the
            // YouTubeModel has cookies attached, so `HomeScreenResponse` returns the user's
            // personalized feed (subscriptions, watch history hints, etc.) instead of the
            // anonymous discovery grid.
            .onChange(of: AuthState.shared.status, initial: false) { _, _ in
                Task { await model.refresh() }
            }
            .errorToast($model.errorState)
        }
    }

    /// The idle (non-searching) view: recent searches on top, then the home video feed.
    /// Regular width (iPad, Mac) lays the feed out as a tile grid; compact width keeps the
    /// single-column list.
    @ViewBuilder
    private var homeFeed: some View {
        if horizontalSizeClass == .regular {
            homeGrid
        } else {
            homeList
        }
    }

    /// Compact-width feed. Single `List` with `.plain` style so the recents section and the
    /// feed share row recycling and scroll smoothly together.
    @ViewBuilder
    private var homeList: some View {
        List {
            if !history.isEmpty {
                recentSearchesSection
            }

            if model.sections.isEmpty && !model.isLoading {
                EmptyStateView(
                    systemImage: "play.rectangle.on.rectangle",
                    title: "Nothing here yet",
                    message: "Pull to refresh or sign in to see your home feed."
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            ForEach(model.sections) { section in
                if let title = section.title {
                    SectionHeader(title: title)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                ForEach(section.videos) { video in
                    Group {
                        if model.removedVideoIDs.contains(video.id) {
                            RemovedVideoPlaceholder {
                                Task { await model.undoNotInterested(video) }
                            }
                        } else {
                            VideoCard(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        guard section.id == model.sections.last?.id else { return }
                        guard section.videos.suffix(5).contains(where: { $0.id == video.id }) else { return }
                        guard model.continuationToken != nil, !model.isLoading else { return }
                        Task { await model.loadMore() }
                    }
                }
            }

            if model.isLoading {
                LoadingView()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .environment(\.notInterestedAction, notInterestedAction)
    }

    /// "Not interested" in the home feed's ⋯ menus. Only the feed sets it, so the search
    /// results sharing this screen don't offer it.
    private var notInterestedAction: NotInterestedAction {
        NotInterestedAction(
            isAvailable: { model.canMarkNotInterested($0) },
            perform: { video in Task { await model.markNotInterested(video) } }
        )
    }

    /// Regular-width feed: recent searches as a row of chips, then each feed section as a
    /// `VideoTileGrid`. Pagination mirrors `homeList` — the last section's trailing tiles
    /// trigger `loadMore()`.
    private var homeGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !history.isEmpty {
                    recentSearchChips
                }

                if model.sections.isEmpty && !model.isLoading {
                    EmptyStateView(
                        systemImage: "play.rectangle.on.rectangle",
                        title: "Nothing here yet",
                        message: "Pull to refresh or sign in to see your home feed."
                    )
                }

                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if let title = section.title {
                            SectionHeader(title: title)
                        }
                        VideoTileGrid(
                            videos: section.videos,
                            onPlay: { player.load($0) },
                            onItemAppear: { video in
                                guard section.id == model.sections.last?.id else { return }
                                guard section.videos.suffix(5).contains(where: { $0.id == video.id }) else { return }
                                guard model.continuationToken != nil, !model.isLoading else { return }
                                Task { await model.loadMore() }
                            },
                            removedVideoIDs: model.removedVideoIDs,
                            onUndoRemove: { video in Task { await model.undoNotInterested(video) } }
                        )
                        .padding(.horizontal)
                    }
                }

                if model.isLoading {
                    LoadingView()
                }
            }
            .padding(.vertical)
        }
        .environment(\.notInterestedAction, notInterestedAction)
    }

    /// Regular-width counterpart of `recentSearchesSection`: a horizontally scrolling row of
    /// capsules. Long-press a chip to delete it; the header's Clear button wipes them all.
    private var recentSearchChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent searches")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear", role: .destructive) {
                    for entry in history { modelContext.delete(entry) }
                    try? modelContext.save()
                }
                .font(.caption)
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(history.prefix(10))) { entry in
                        Button {
                            searchModel.query = entry.query
                            Task { await runSearch() }
                        } label: {
                            Label(entry.query, systemImage: "clock.arrow.circlepath")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                modelContext.delete(entry)
                                try? modelContext.save()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// "Recent searches" pinned above the home feed. Caps at the 10 most-recent entries
    /// so the section doesn't push the feed below the fold on a long-tail history.
    /// Per-row swipe-to-delete and a section-level Clear button cover the two grooming
    /// cases. Tapping a row populates the search field and re-runs the search.
    @ViewBuilder
    private var recentSearchesSection: some View {
        let recent = Array(history.prefix(10))
        Section {
            ForEach(recent) { entry in
                Button {
                    searchModel.query = entry.query
                    Task { await runSearch() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        Text(entry.query)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        modelContext.delete(entry)
                        try? modelContext.save()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            HStack {
                Text("Recent searches")
                Spacer()
                Button("Clear", role: .destructive) {
                    for entry in history { modelContext.delete(entry) }
                    try? modelContext.save()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .textCase(nil)
            }
        }
    }

    /// Persists the trimmed query to history (upsert by query string) then fires
    /// `searchModel.submit()`. Same logic the dedicated Search tab used to run.
    private func runSearch() async {
        let trimmed = searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = history.first(where: { $0.query == trimmed }) {
            existing.searchedAt = .now
        } else {
            modelContext.insert(SearchHistoryEntry(query: trimmed))
        }
        try? modelContext.save()
        await searchModel.submit()
    }
}
