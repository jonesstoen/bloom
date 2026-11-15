import ImmichKit
import SwiftUI

/// The photos still to back up, newest first: a thumbnail, the date and where each stands (uploading,
/// queued, waiting for Wi-Fi, not checked yet, or trying again later), so it is clear why one isn't on the
/// server yet. Read only. Pushed from the Backup screen.
struct BackupRemainingList: View {
    let model: BackupModel

    var body: some View {
        List {
            if model.remainingItems.isEmpty {
                Section {
                    ContentUnavailableView(tr("Nothing Remaining"), systemImage: "checkmark.circle")
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(model.remainingItems) { item in
                        RemainingItemRow(item: item, model: model)
                    }
                } footer: {
                    if model.counts.pending > model.remainingItems.count {
                        Text(tr("Showing the first %lld.", Int64(model.remainingItems.count)))
                    }
                }
            }
        }
        .navigationTitle(tr("Remaining"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct RemainingItemRow: View {
    let item: BackupModel.RemainingItem
    let model: BackupModel

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
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch item.status {
        case .uploading: tr("Uploading")
        case .waiting: tr("Waiting to Upload")
        case .waitingForWiFi: tr("Waiting for Wi-Fi")
        case .notChecked: tr("Not Checked Yet")
        case let .retrying(at): tr("Trying again at %@", at.formatted(.dateTime.hour().minute().locale(Localization.locale)))
        }
    }
}

#Preview("Remaining") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupRemainingList(model: model) }
        .task { await model.loadPreview(remaining: 6) }
}

#Preview("Remaining, empty") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupRemainingList(model: model) }
        .task { await model.load() }
}
