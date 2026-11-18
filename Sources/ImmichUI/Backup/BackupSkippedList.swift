import ImmichKit
import SwiftUI

/// The photos the owner told Bloom to stop trying: a thumbnail and date per item, and Include Again to
/// take one back into the backup. Nothing here is read or uploaded. Pushed from the Backup screen.
struct BackupSkippedList: View {
    let model: BackupModel

    var body: some View {
        List {
            if model.skippedItems.isEmpty {
                // Included everything again (or nothing was skipped): say so instead of an empty list.
                Section {
                    ContentUnavailableView(tr("Nothing Skipped"), systemImage: "checkmark.circle")
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(model.skippedItems) { item in
                        SkippedItemRow(item: item, model: model, isDisabled: model.isWorking) {
                            Task { await model.includeAgain([item.id]) }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Bloom doesn't read or upload these photos. Include one again to back it up."))
                        if model.counts.skipped > model.skippedItems.count {
                            Text(tr("Showing the first %lld.", Int64(model.skippedItems.count)))
                        }
                        if let error = model.error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle(tr("Skipped"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct SkippedItemRow: View {
    let item: BackupModel.SkippedItem
    let model: BackupModel
    let isDisabled: Bool
    let includeAgain: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BackupThumbnail(id: item.id, model: model)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            if let date = item.date {
                Text(date, format: .dateTime.day().month(.abbreviated).year().locale(Localization.locale))
            }
            Spacer(minLength: 8)
            Button(tr("Include Again"), action: includeAgain)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(isDisabled)
        }
    }
}

#Preview("Skipped") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupSkippedList(model: model) }
        .task { await model.loadPreview(skipped: 3) }
}

#Preview("Skipped, empty") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupSkippedList(model: model) }
        .task { await model.load() }
}
