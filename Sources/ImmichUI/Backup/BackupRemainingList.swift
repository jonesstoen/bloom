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
            BackupCheckingNowSection(model: model)
            if model.remainingItems.isEmpty, model.checkingItem == nil {
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
                        .accessibilityElement(children: .combine)
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
                            Text(tr("Showing %lld.", Int64(model.remainingItems.count)))
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

/// "Checking Now": the photo the scan reads, with how far the check has got. It stays in its own section
/// below too, so rows don't move as the photo changes. Its own view, so those changes redraw only this
/// section (the list reads `checkingItem` only while it has no remaining items).
private struct BackupCheckingNowSection: View {
    let model: BackupModel

    var body: some View {
        if let item = model.checkingItem {
            Section {
                HStack(spacing: 12) {
                    BackupThumbnail(id: item.id, model: model)
                        .id(item.id) // a new photo starts without the last one's image
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        if let date = item.date {
                            Text(date, format: .dateTime.day().month(.abbreviated).year().locale(Localization.locale))
                        }
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(tr("Reading and comparing with the server…"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            } header: {
                HStack {
                    Text(tr("Checking Now"))
                    Spacer()
                    if let progress = model.progress {
                        Text(tr("%lld of %lld", Int64(progress.done), Int64(progress.total)))
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text(tr("Bloom reads each photo once to see whether your server already has it. Photos only in iCloud are downloaded first."))
            }
        }
    }
}

struct RemainingItemRow: View {
    let item: BackupModel.RemainingItem
    let model: BackupModel

    /// "Failed 5 times · trying again at 14:05", or "… trying again Tuesday at 09:00" when it isn't today.
    static func retryLine(at: Date, failures: Int, now: Date = .now) -> String {
        let locale = Localization.locale
        let time = at.formatted(.dateTime.hour().minute().locale(locale))
        let retry = Calendar.current.isDate(at, inSameDayAs: now)
            ? tr("Trying again at %@", time)
            : tr("Trying again %@ at %@", at.formatted(.dateTime.weekday(.wide).locale(locale)), time)
        return failures > 1 ? tr("Failed %lld times · %@", Int64(failures), retry) : retry
    }

    /// What the progress is of: the date taken, or the section's name without one.
    private var accessibilityLabel: String {
        item.date?.formatted(.dateTime.day().month(.wide).year().locale(Localization.locale)) ?? tr("Uploading Now")
    }

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
                    RemainingItemProgress(id: item.id, label: accessibilityLabel, progress: model.uploadProgress)
                case let .retrying(at, failures, reason):
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.retryLine(at: at, failures: failures))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let reason {
                            Text(reason)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                    }
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
    let label: String
    let progress: BackupUploadProgress

    var body: some View {
        Group {
            if let fraction = progress.fractions[id] {
                ProgressView(value: fraction)
            } else {
                ProgressView(value: nil as Double?)
                    .progressViewStyle(.linear)
            }
        }
        .accessibilityLabel(label)
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

#Preview("Remaining, checking") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupRemainingList(model: model) }
        .task { await model.loadPreview(remaining: 6, checking: true) }
}

#Preview("Remaining, empty") {
    let model = BackupModel.preview(selected: ["recents"])
    NavigationStack { BackupRemainingList(model: model) }
        .task { await model.load() }
}
