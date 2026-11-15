import CoreGraphics
import ImmichKit
import SwiftUI

/// The photos that were on the server and no longer are: a thumbnail and date per item, whether it is in
/// the server's trash, and Re-upload for one item or all. Nothing here is uploaded or restored until the
/// user asks. Pushed from the Backup screen.
struct BackupDeletedOnServerList: View {
    let model: BackupModel

    var body: some View {
        List {
            if model.deletedItems.isEmpty {
                // Re-uploaded everything (or nothing was deleted): say so instead of an empty list.
                Section {
                    ContentUnavailableView(tr("Nothing Deleted on Server"), systemImage: "checkmark.circle")
                        .listRowBackground(Color.clear)
                }
            } else {
                itemsSection
                reuploadAllSection
            }
        }
        .navigationTitle(tr("Deleted on Server"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var itemsSection: some View {
        Section {
            ForEach(model.deletedItems) { item in
                DeletedItemRow(item: item, model: model, isDisabled: model.isWorking) {
                    Task { await model.reupload([item.id]) }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("These photos were on your server and are gone from it. Bloom doesn't upload them again unless you ask."))
                if model.counts.deletedOnServer > model.deletedItems.count {
                    Text(tr("Showing the first %lld.", Int64(model.deletedItems.count)))
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
    }

    private var reuploadAllSection: some View {
        Section {
            Button(tr("Re-upload All")) { Task { await model.reuploadAll() } }
                .disabled(model.isWorking)
        }
    }
}

private struct DeletedItemRow: View {
    let item: BackupModel.DeletedItem
    let model: BackupModel
    let isDisabled: Bool
    let reupload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BackupThumbnail(id: item.id, model: model)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let date = item.date {
                    Text(date, format: .dateTime.day().month(.abbreviated).year().locale(Localization.locale))
                }
                Text(item.isTrashed ? tr("In the Trash") : tr("Deleted"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(tr("Re-upload"), action: reupload)
                .buttonStyle(.borderless)
                .disabled(isDisabled)
        }
    }
}

/// A photo-library thumbnail, loaded when the row appears (the model decodes and caches it), or a
/// placeholder while there is none (the photo is gone from the iPhone, or the library hasn't answered yet).
struct BackupThumbnail: View {
    let id: String
    let model: BackupModel
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .task(id: id) { image = await model.thumbnail(for: id) }
    }
}

#Preview("Deleted on Server") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupDeletedOnServerList(model: model) }
        .task { await model.loadPreview(deletedOnServer: 4) }
}

#Preview("Deleted on Server, empty") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupDeletedOnServerList(model: model) }
        .task { await model.load() }
}
