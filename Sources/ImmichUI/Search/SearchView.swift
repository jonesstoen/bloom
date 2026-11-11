import ImmichKit
import SwiftUI

public struct SearchView: View {
    @State private var model: SearchModel
    @State private var images = ThumbnailImageCache()
    @State private var selected: Asset?
    @State private var transitionID: String?
    @Namespace private var transition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: SearchModel(service: service, loader: loader))
    }

    public var body: some View {
        Group {
            if model.query == nil { suggestions }
            else { results }
        }
        .navigationTitle("Search")
        .searchable(text: $model.text, prompt: "Photos, people, places…")
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
        List {
            Section {
                Label("Describe a photo, such as ‘a dog on the beach’.", systemImage: "sparkle.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            if model.loadingSuggestions { ProgressView() }
            if let error = model.suggestionsError {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.loadSuggestions() } }
                }
            }
            if !model.people.isEmpty {
                Section("People") {
                    ForEach(model.people) { person in
                        Button { model.selectPerson(person) } label: {
                            HStack {
                                CollectionThumbnail(key: .person(person.id), loader: model.loader, symbol: "person.fill")
                                    .frame(width: 44, height: 44).clipShape(Circle())
                                Text(person.name).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            if !model.places.isEmpty {
                Section("Places") {
                    ForEach(model.places, id: \.self) { place in
                        Button { model.selectCity(place) } label: { Label(place, systemImage: "mappin.and.ellipse") }
                    }
                }
            }
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(model.assets) { asset in
                        Button { transitionID = asset.id; selected = asset } label: {
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
                if model.isLoading { ProgressView().padding() }
                if let error = model.error {
                    VStack {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { Task {
                            if model.assets.isEmpty { await model.search() } else { await model.loadMore() }
                        } }
                    }.padding()
                } else if model.hasSearched && model.assets.isEmpty && !model.isLoading {
                    ContentUnavailableView.search(text: model.text)
                } else if model.next != nil && !model.isLoading {
                    Button("Load More") { Task { await model.loadMore() } }.padding()
                }
            }
            .onChange(of: transitionID) { old, id in
                if old != nil, let id, selected?.id != id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func viewer(_ asset: Asset) -> some View {
        AssetViewer(assets: model.assets, selectedID: asset.id, service: model.service, loader: model.loader) { id in
            transitionID = id
            if id == model.assets.last?.id { Task { await model.loadMore() } }
        }
    }
}

#Preview("Search") { NavigationStack { SearchView(service: MockImmichService.preview) } }
