import ImmichKit
import SwiftUI

public struct PeopleView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: CollectionsModel

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: CollectionsModel(service: service, loader: loader))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CollectionLoadState(isEmpty: model.people.isEmpty, isLoading: model.loadingPeople,
                                    hasLoaded: model.loadedPeople, error: model.peopleError,
                                    errorTitle: tr("Can't Load People"),
                                    emptyTitle: tr("No People"), emptySymbol: "person.crop.circle",
                                    emptyDescription: tr("People recognized by your Immich server appear here."),
                                    retry: { await model.loadPeople() }) {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 24) {
                        ForEach(model.people) { person in
                            NavigationLink {
                                PersonDetailView(person: person, service: model.service, loader: model.loader)
                            } label: {
                                personCard(person)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .navigationTitle(tr("People"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { if !model.loadedPeople { await model.loadPeople() } }
        .refreshable { await model.loadPeople() }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 220 : 100),
                  spacing: 20, alignment: .top)]
    }

    private func personCard(_ person: Person) -> some View {
        let name = person.isNamed ? person.name : tr("Unnamed Person")
        return VStack(spacing: 10) {
            CollectionThumbnail(key: .person(person.id), loader: model.loader, symbol: "person.fill")
                .clipShape(Circle())
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 200 : 160)
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

public struct PersonDetailView: View {
    @State private var model: LibraryGridModel
    private let person: Person

    public init(person: Person, service: any ImmichService, loader: ImageLoader? = nil) {
        self.person = person
        _model = State(initialValue: LibraryGridModel(service: service, options: .person(person.id), loader: loader))
    }

    public var body: some View { LibraryGridView(model: model, title: person.isNamed ? person.name : tr("Unnamed Person")) }
}

#Preview("People") { NavigationStack { PeopleView(service: MockImmichService.preview) } }
#Preview("People — large text") {
    NavigationStack { PeopleView(service: MockImmichService.preview) }
        .environment(\.dynamicTypeSize, .accessibility3)
}
#Preview("People — empty") {
    NavigationStack { PeopleView(service: MockImmichService()) }
}
#Preview("Person detail") {
    NavigationStack { PersonDetailView(person: MockLibrary.standard.people[0], service: MockImmichService.preview) }
}
