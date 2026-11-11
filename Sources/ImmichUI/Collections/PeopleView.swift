import ImmichKit
import SwiftUI

public struct PeopleView: View {
    @State private var model: CollectionsModel

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: CollectionsModel(service: service, loader: loader))
    }

    public var body: some View {
        ScrollView {
            if let error = model.peopleError {
                ContentUnavailableView {
                    Label(tr("Can't Load People"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button(tr("Try Again")) { Task { await model.loadPeople() } }
                }
            }
            if model.loadingPeople && model.people.isEmpty { ProgressView().padding() }
            if model.loadedPeople && model.people.isEmpty {
                ContentUnavailableView(tr("No People"), systemImage: "person.crop.circle", description: Text(tr("People recognized by your Immich server appear here.")))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 20)], spacing: 24) {
                ForEach(model.people) { person in
                    NavigationLink {
                        PersonDetailView(person: person, service: model.service, loader: model.loader)
                    } label: {
                        VStack(spacing: 8) {
                            CollectionThumbnail(key: .person(person.id), loader: model.loader, symbol: "person.fill")
                                .clipShape(Circle())
                            Text(person.isNamed ? person.name : tr("Unnamed Person"))
                                .font(.headline).foregroundStyle(.primary).lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                    }.buttonStyle(.plain)
                }
            }.padding()
        }
        .navigationTitle(tr("People"))
        .task { if !model.loadedPeople { await model.loadPeople() } }
        .refreshable { await model.loadPeople() }
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
#Preview("Person detail") {
    NavigationStack { PersonDetailView(person: MockLibrary.standard.people[0], service: MockImmichService.preview) }
}
