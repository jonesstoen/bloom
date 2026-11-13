import ImmichKit
import SwiftUI

/// "Add to Album": the albums to pick from, creating a new one, and the outcome.
@MainActor
@Observable
final class AlbumPickerModel {
    private(set) var albums: [Album] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var loadError: String?
    /// Set when done: what happened, shown before closing.
    private(set) var outcome: String?
    let assetIDs: [String]
    @ObservationIgnored private let service: any ImmichService

    init(service: any ImmichService, assetIDs: [String]) {
        self.service = service
        self.assetIDs = assetIDs
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { albums = try await service.albumsForAdding(); loadError = nil }
        catch { loadError = tr("Couldn't load albums. Please try again.") }
    }

    func add(to album: Album) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await service.addAssets(toAlbum: album.id, assetIDs: assetIDs)
            outcome = Self.message(for: result, albumName: album.name)
            NotificationCenter.default.post(name: .bloomAlbumsDidChange, object: nil)
        } catch {
            outcome = tr("Couldn't add to the album. Please try again.")
        }
    }

    func createAlbum(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, !name.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        let albumID: String
        do {
            albumID = try await service.createAlbum(name: name, assetIDs: [])
        } catch {
            outcome = tr("Couldn't create the album. Please try again.")
            return
        }
        defer { NotificationCenter.default.post(name: .bloomAlbumsDidChange, object: nil) }
        let createdMessage = tr("Created «%@».", name)
        guard !assetIDs.isEmpty else {
            outcome = createdMessage
            return
        }
        do {
            let result = try await service.addAssets(toAlbum: albumID, assetIDs: assetIDs)
            outcome = createdMessage + " " + Self.message(for: result, albumName: name)
        } catch {
            outcome = tr("Created «%@», but couldn't confirm the added items. Open the album before trying again.", name)
        }
    }

    static func message(for result: AlbumAddResult, albumName: String) -> String {
        var parts = [tr("Added %lld items to «%@».", Int64(result.addedIDs.count), albumName)]
        if !result.alreadyInAlbumIDs.isEmpty { parts.append(tr("%lld were already there.", Int64(result.alreadyInAlbumIDs.count))) }
        if !result.failedIDs.isEmpty { parts.append(tr("%lld couldn't be added.", Int64(result.failedIDs.count))) }
        return parts.joined(separator: " ")
    }
}

/// The sheet behind "Add to Album": New Album… and albums the user can edit.
struct AlbumPickerSheet: View {
    @State private var model: AlbumPickerModel
    @State private var naming = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    init(service: any ImmichService, assetIDs: [String]) {
        _model = State(initialValue: AlbumPickerModel(service: service, assetIDs: assetIDs))
    }

    var body: some View {
        NavigationStack {
            List {
                Button { naming = true } label: { Label(tr("New Album…"), systemImage: "plus.rectangle.on.rectangle") }
                Section(tr("Albums")) {
                    if model.isLoading && model.albums.isEmpty { ProgressView() }
                    if let error = model.loadError { Text(error).foregroundStyle(.secondary) }
                    ForEach(model.albums) { album in
                        Button { Task { await model.add(to: album) } } label: {
                            LabeledContent(album.name, value: tr("%lld items", Int64(album.assetCount)))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .disabled(model.isWorking)
            .overlay { if model.isWorking { ProgressView() } }
            .navigationTitle(tr("Add to Album"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                        .disabled(model.isWorking)
                }
            }
            .alert(tr("New Album"), isPresented: $naming) {
                TextField(tr("Title"), text: $newName)
                Button(tr("Cancel"), role: .cancel) { newName = "" }
                Button(tr("Save")) { let name = newName; newName = ""; Task { await model.createAlbum(named: name) } }
            }
            .alert(model.outcome ?? "", isPresented: Binding(get: { model.outcome != nil }, set: { if !$0 { dismiss() } })) {
                Button(tr("OK")) { dismiss() }
            }
            .task { await model.load() }
        }
        #if os(iOS)
        .interactiveDismissDisabled(model.isWorking)
        #endif
    }
}

#Preview("Add to album") {
    AlbumPickerSheet(service: MockImmichService.preview, assetIDs: Array(MockLibrary.standard.assets.prefix(3).map(\.id)))
}
