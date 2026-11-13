import ImmichKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Backup: how many photos are on the server already, which album choices steer that, and the
/// button to check again. Present it inside a `NavigationStack`.
struct BackupView: View {
    let model: BackupModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            switch model.access {
            case .denied:
                deniedSection
            case .limited:
                limitedSection
                content
            default:
                content
            }
            Section {} footer: {
                // Phase 1 only reads. Reword once uploading exists.
                Text(tr("Uploading comes in a later update.") + "\n" + tr("Bloom never deletes photos from your iPhone."))
            }
        }
        .navigationTitle(tr("Backup"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("Done")) { dismiss() }
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        albumsSection
        countsSection
        checkSection
        failedSection
        cellularSection
    }

    // MARK: Access

    private var deniedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(tr("Photo Access Is Off"), systemImage: "lock.fill")
                    .font(.headline)
                Text(tr("Allow Bloom to read your photos in Settings so it can check which ones are already on your server."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                settingsButton
            }
            .padding(.vertical, 4)
        }
    }

    private var limitedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(tr("Limited Access"), systemImage: "photo.badge.exclamationmark")
                    .font(.headline)
                Text(tr("Bloom can only see the photos you selected. Allow access to all photos to check your whole library."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                settingsButton
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var settingsButton: some View {
        #if os(iOS)
        Button(tr("Open Settings")) {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .buttonStyle(.bordered)
        #endif
    }

    // MARK: Sections

    private var albumsSection: some View {
        Section {
            NavigationLink {
                BackupAlbumPicker(model: model)
            } label: {
                LabeledContent(tr("Albums"), value: model.selectionSummary)
            }
        }
    }

    private var countsSection: some View {
        Section {
            LabeledContent(tr("Total")) { count(model.counts.total) }
            LabeledContent(tr("On Server")) { count(model.counts.backedUp) }
            LabeledContent {
                count(model.remaining)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Remaining"))
                    if model.counts.waitingForWiFi > 0 {
                        Text(tr("%lld waiting for Wi-Fi", Int64(model.counts.waitingForWiFi)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // So that Total always equals On Server + Remaining + Problems.
            if model.counts.failed > 0 {
                LabeledContent(tr("Problems")) { count(model.counts.failed) }
            }
        }
    }

    private func count(_ value: Int) -> some View {
        Text(value, format: .number)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var checkSection: some View {
        Section {
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Checking %@ of %@", number(progress.done), number(progress.total)))
                        .monospacedDigit()
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                }
                .accessibilityElement(children: .combine)
                Button(tr("Cancel"), role: .cancel) { model.cancel() }
            } else if model.isScanning {
                HStack {
                    ProgressView()
                    Button(tr("Cancel"), role: .cancel) { model.cancel() }
                }
            } else {
                Button(tr("Check Now")) { Task { await model.scan() } }
                    .disabled(!model.canCheck)
            }
        } footer: {
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var failedSection: some View {
        if !model.failedItems.isEmpty {
            Section {
                ForEach(model.failedItems) { item in
                    Label(item.reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.multicolor)
                }
            } header: {
                Text(tr("Items with Problems"))
            } footer: {
                if model.counts.failed > model.failedItems.count {
                    Text(tr("Showing the first %lld.", Int64(model.failedItems.count)))
                }
            }
        }
    }

    private var cellularSection: some View {
        Section {
            @Bindable var model = model
            Toggle(tr("Photos over Cellular"), isOn: $model.settings.photosOnCellular)
            Toggle(tr("Videos over Cellular"), isOn: $model.settings.videosOnCellular)
        } footer: {
            Text(tr("Photos that exist only in iCloud are checked on Wi-Fi, unless you allow cellular here."))
        }
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(Localization.locale))
    }
}

#Preview("Backup") {
    NavigationStack { BackupView(model: .preview(selected: ["recents"], excluded: ["screenshots"])) }
}

#Preview("Backup, first setup") {
    NavigationStack { BackupView(model: .preview()) }
}

#Preview("Backup, limited access") {
    NavigationStack { BackupView(model: .preview(selected: ["recents"], access: .limited)) }
}

#Preview("Backup, photo access off") {
    NavigationStack { BackupView(model: .preview(access: .denied)) }
}

extension BackupModel {
    /// A model on the preview library and mock server, with its own throwaway index.
    static func preview(
        selected: Set<String> = [], excluded: Set<String> = [], access: PhotoAccess = .full
    ) -> BackupModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupPreview-\(UUID().uuidString)", isDirectory: true)
        let model = BackupModel(
            source: PreviewPhotoLibrary(access: access),
            service: MockImmichService.preview,
            directory: directory,
            network: PreviewNetwork(),
            defaults: UserDefaults(suiteName: "BackupPreview") ?? .standard)
        if !selected.isEmpty || !excluded.isEmpty {
            model.setSelection(BackupSelection(included: selected, excluded: excluded))
        }
        return model
    }
}

private struct PreviewNetwork: NetworkConditions {
    var isOnCellular: Bool { false }
}
