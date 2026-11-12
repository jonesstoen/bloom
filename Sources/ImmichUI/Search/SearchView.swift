import ImmichKit
import SwiftUI

public struct SearchView: View {
    @State private var model: SearchModel
    @State private var images = ThumbnailImageCache()
    @State private var selected: Asset?
    @State private var transitionID: String?
    @Namespace private var transition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var personSize = 88

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: SearchModel(service: service, loader: loader))
    }

    public init(model: SearchModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Group {
            if model.query == nil { suggestions }
            else { results }
        }
        .background(.background)
        .navigationTitle(tr("Search"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .searchable(text: $model.text, prompt: tr("Photos, people, places…"))
        .onSubmit(of: .search) { model.rememberCurrentSearch() }
        .task { await model.loadSuggestions() }
        .task(id: model.query) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await model.search()
        }
        #if os(iOS)
        .fullScreenCover(item: $selected) { asset in
            if reduceMotion { viewer(asset) }
            else { viewer(asset).navigationTransition(.zoom(sourceID: transitionID ?? asset.id, in: transition)) }
        }
        #else
        .sheet(item: $selected) { asset in viewer(asset).frame(minWidth: 700, minHeight: 500) }
        #endif
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(tr("Search your photos by describing what you remember."))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                    suggestionRow
                }
                if !model.recentSearches.isEmpty { recentSearches }
                if !model.people.isEmpty { peopleRow }
                if !model.places.isEmpty { placesRow }
                if model.loadingSuggestions {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                if let error = model.suggestionsError {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).foregroundStyle(.secondary)
                        Button(tr("Try Again")) { Task { await model.loadSuggestions() } }
                            .frame(minHeight: 44)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(tr("Suggestions"))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    suggestionChip(tr("A dog on the beach"), symbol: "dog")
                    suggestionChip(tr("Sunsets"), symbol: "sun.horizon")
                    suggestionChip(tr("Snowy mountains"), symbol: "mountain.2")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func suggestionChip(_ text: String, symbol: String) -> some View {
        Button { model.selectSuggestion(text) } label: {
            Label(text, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .photosGlass(in: Capsule())
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("Recent Searches")).font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button(tr("Clear")) { model.clearRecentSearches() }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .photosGlass(in: Capsule())
            }
            ForEach(model.recentSearches) { recent in
                Button { model.selectRecent(recent) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(recent.text)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: recent.systemImage)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .font(.body)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if recent.id != model.recentSearches.last?.id {
                    Divider().padding(.leading, 36)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(tr("People"))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.people) { person in
                        Button { model.selectPerson(person) } label: {
                            VStack(spacing: 8) {
                                CollectionThumbnail(key: .person(person.id), loader: model.loader, symbol: "person.fill")
                                    .frame(width: personSize, height: personSize)
                                    .clipShape(Circle())
                                Text(person.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: personSize)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(person.name)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var placesRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(tr("Places"))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(model.places, id: \.self) { place in
                        Button { model.selectCity(place) } label: {
                            Label(place, systemImage: "mappin.and.ellipse")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(minHeight: 44)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .photosGlass(in: Capsule())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 20)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(tr("Results"))
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(model.assets) { asset in
                            Button {
                                model.rememberCurrentSearch()
                                transitionID = asset.id
                                selected = asset
                            } label: {
                                ThumbnailCell(asset: asset, loader: model.loader, images: images)
                            }
                            .buttonStyle(.plain)
                            .id(asset.id)
                            #if os(iOS)
                            .matchedTransitionSource(id: asset.id, in: transition)
                            #endif
                            .onAppear {
                                if asset.id == model.assets.last?.id && model.error == nil {
                                    Task { await model.loadMore() }
                                }
                            }
                        }
                    }
                }
                if model.isLoading || !model.hasSearched {
                    ProgressView().frame(maxWidth: .infinity).padding(32)
                }
                if let error = model.error {
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(.secondary)
                        Button(tr("Try Again")) { Task {
                            if model.assets.isEmpty { await model.search() } else { await model.loadMore() }
                        } }
                        .frame(minHeight: 44)
                    }.padding(20)
                } else if model.hasSearched && model.assets.isEmpty && !model.isLoading {
                    ContentUnavailableView.search(text: model.text)
                } else if model.next != nil && !model.isLoading {
                    Button(tr("Load More")) { Task { await model.loadMore() } }
                        .frame(minHeight: 44).padding()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: transitionID) { old, id in
                if old != nil, let id, selected?.id != id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func viewer(_ asset: Asset) -> some View {
        AssetViewer(assets: model.assets, selectedID: asset.id, service: model.service, loader: model.loader,
                    thumbnails: images, onSelection: { id in
            transitionID = id
            if id == model.assets.last?.id { Task { await model.loadMore() } }
        })
    }
}

#Preview("Search") { NavigationStack { SearchView(service: MockImmichService.preview) } }
#Preview("Search, large text") {
    NavigationStack { SearchView(service: MockImmichService.preview) }
        .environment(\.dynamicTypeSize, .accessibility2)
}
