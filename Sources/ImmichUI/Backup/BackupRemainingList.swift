import ImmichKit
import SwiftUI

/// The photos still to back up: how much of the selection is on the server, then a section per state
/// (uploading now, with each upload's progress; waiting to upload; waiting for Wi-Fi; trying again later;
/// not checked yet), each newest first, so it is clear why one isn't on the server yet. Read only. Pushed
/// from the Backup screen.
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
                if let fraction = model.backedUpFraction {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr(
                                "%lld of %lld backed up", Int64(model.counts.backedUp),
                                Int64(model.counts.backedUp + model.counts.pending)))
                                .font(.subheadline)
                            ProgressView(value: fraction)
                        }
                        .padding(.vertical, 4)
                    }
                }
                let sections = model.remainingSections
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            RemainingItemRow(item: item, model: model)
                        }
                    } header: {
                        HStack {
                            Text(Self.title(of: section.kind))
                            Spacer()
                            Text(section.items.count, format: .number)
                        }
                    } footer: {
                        if section.id == sections.last?.id, model.isRemainingCut {
                            Text(tr("Showing the first %lld.", Int64(model.remainingItems.count)))
                        }
                    }
                }
            }
        }
        .navigationTitle(tr("Remaining"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Progress at most four times a second; what is in flight at the Backup screen's pace.
            var tick = 0
            while !Task.isCancelled {
                if tick % 12 == 0 { await model.refreshBackgroundStatus() }
                await model.refreshUploadProgress()
                tick += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func title(of kind: BackupModel.RemainingSection.Kind) -> String {
        switch kind {
        case .uploading: tr("Uploading Now")
        case .waiting: tr("Waiting to Upload")
        case .waitingForWiFi: tr("Waiting for Wi-Fi")
        case .retrying: tr("Trying Again Later")
        case .notChecked: tr("Not Checked Yet")
        }
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
            VStack(alignment: .leading, spacing: 4) {
                if let date = item.date {
                    Text(date, format: .dateTime.day().month(.abbreviated).year().locale(Localization.locale))
                }
                switch item.status {
                case .uploading:
                    RemainingItemProgress(id: item.id, progress: model.uploadProgress)
                case let .retrying(at):
                    Text(tr("Trying again at %@", at.formatted(.dateTime.hour().minute().locale(Localization.locale))))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .waiting, .waitingForWiFi, .notChecked:
                    EmptyView()
                }
            }
        }
    }
}

/// The progress of one upload in flight. Reads only `BackupUploadProgress`, so its updates redraw this and
/// not the list.
private struct RemainingItemProgress: View {
    let id: String
    let progress: BackupUploadProgress

    var body: some View {
        if let fraction = progress.fractions[id] {
            ProgressView(value: fraction)
        } else {
            ProgressView(value: nil as Double?)
                .progressViewStyle(.linear)
        }
    }
}

#Preview("Remaining") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupRemainingList(model: model) }
        .task { await model.loadPreview(remaining: 6) }
}

#Preview("Remaining, uploading") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupRemainingList(model: model) }
        .task { await model.loadPreview(remaining: 6, uploading: 2) }
}

#Preview("Remaining, empty") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupRemainingList(model: model) }
        .task { await model.load() }
}
