import ImmichKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Backup: the switch that uploads while the app is open, how many photos are on the server already,
/// which album choices steer that, the photos deleted on the server, and the button to check again.
/// Present it inside a `NavigationStack`.
struct BackupView: View {
    let model: BackupModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var model = model
        List {
            switch model.access {
            case .denied:
                deniedSection
            case .limited:
                limitedSection
                content
            case .full, .notDetermined, nil:
                // Not yet known, or the system prompt is up: show the content, no scan is possible.
                content
            }
            Section {} footer: {
                Text(tr("Bloom never deletes photos from your iPhone."))
            }
        }
        .navigationTitle(tr("Backup"))
        // Turning the switch on before choosing albums opens the picker; popping it clears the flag.
        .navigationDestination(isPresented: $model.needsAlbumChoice) { BackupAlbumPicker(model: model) }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("Done")) { dismiss() }
            }
        }
        .task { await model.load(); model.runner.backupScreenOpened() }
        // Uploads go on while the screen is open (and after it is closed): look at them every few seconds.
        .task {
            while !Task.isCancelled {
                await model.refreshBackgroundStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        #if os(iOS)
        // Keep the screen awake while a scan or an upload runs: auto-lock would suspend the app and stop
        // a long first run.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake }
        .onChange(of: keepsScreenAwake) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    #if os(iOS)
    /// While the Backup screen is open, a scan or an upload keeps the screen from locking.
    private var keepsScreenAwake: Bool { model.isScanning || model.runner.isUploading }
    #endif

    @ViewBuilder private var content: some View {
        switchSection
        BackupBackgroundSection(model: model)
        albumsSection
        BackupCountsSection(model: model)
        BackupUploadSection(model: model)
        BackupCheckSection(model: model)
        BackupFailedItemsSection(model: model)
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

    private var switchSection: some View {
        Section {
            Toggle(tr("Backup"), isOn: Binding(
                get: { model.settings.isEnabled },
                set: { model.setBackupEnabled($0) }))
        }
    }

    private var albumsSection: some View {
        Section {
            NavigationLink {
                BackupAlbumPicker(model: model)
            } label: {
                LabeledContent(tr("Albums"), value: model.selectionSummary)
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
}

/// What the background uploads are doing: how many are under way, when the last one succeeded, why nothing
/// is sent (redirect, Background App Refresh off), and when Bloom backs up. Its own view so the polling
/// status only rebuilds this section.
private struct BackupBackgroundSection: View {
    let model: BackupModel

    var body: some View {
        Section {
            BackupBackgroundRows(
                inFlight: model.inFlightCount, lastBackup: model.lastBackup,
                isRedirectBlocked: model.isRedirectBlocked,
                isRefreshOff: model.isBackgroundRefreshOff && model.settings.isEnabled,
                retryAfterRedirect: { Task { await model.retryAfterRedirect() } })
        } footer: {
            Text(tr("Bloom backs up when it is open and at night while charging. iOS decides the exact time."))
        }
    }
}

private struct BackupBackgroundRows: View {
    let inFlight: Int
    let lastBackup: Date?
    let isRedirectBlocked: Bool
    let isRefreshOff: Bool
    var retryAfterRedirect: () -> Void = {}
    @Environment(\.openURL) private var openURL

    var body: some View {
        if isRedirectBlocked {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    tr("Backup stopped: the server redirected an upload to another address. Check your server setup, then tap Try Again."),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button(tr("Try Again"), action: retryAfterRedirect)
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
        if inFlight > 0 {
            Label(tr("Uploading in the background: %lld", Int64(inFlight)), systemImage: "arrow.up.circle")
                .monospacedDigit()
        }
        if let lastBackup {
            Text(tr("Last backup: %@", Self.relative(lastBackup)))
        }
        if isRefreshOff {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    tr("Background App Refresh is off for Bloom. Turn it on in Settings to back up when Bloom is closed."),
                    systemImage: "arrow.clockwise.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                Button(tr("Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
                #endif
            }
            .padding(.vertical, 4)
        }
    }

    /// "2 hours ago", in the app's language.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localization.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Observe changing counts here instead of rebuilding the whole Backup list.
private struct BackupCountsSection: View {
    let model: BackupModel

    var body: some View {
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
            if model.counts.deletedOnServer > 0 {
                NavigationLink {
                    BackupDeletedOnServerList(model: model)
                } label: {
                    LabeledContent(tr("Deleted on Server")) { count(model.counts.deletedOnServer) }
                }
            }
            // So that Total always equals On Server + Remaining + Deleted on Server + Problems.
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
}

/// "Uploading 4 of 15 · IMG_1234.HEIC" while an upload run goes. Progress changes only rebuild this section.
private struct BackupUploadSection: View {
    let model: BackupModel

    var body: some View {
        if let progress = model.runner.uploadProgress {
            Section {
                BackupUploadRow(progress: progress)
            }
        }
    }
}

private struct BackupUploadRow: View {
    let progress: UploadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        // `done` counts finished items: with a file in flight, that is the next one.
        let current = progress.currentFilename == nil ? progress.done : min(progress.done + 1, progress.total)
        let done = current.formatted(.number.locale(Localization.locale))
        let total = progress.total.formatted(.number.locale(Localization.locale))
        guard let filename = progress.currentFilename else { return tr("Uploading %@ of %@", done, total) }
        return tr("Uploading %@ of %@ · %@", done, total, filename)
    }
}

/// Progress changes only rebuild this section.
private struct BackupCheckSection: View {
    let model: BackupModel

    var body: some View {
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
                Button(tr("Check Now")) { model.runner.checkNow() }
                    .disabled(!model.canCheck)
            }
        } footer: {
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            } else if let status = model.connectionStatus {
                switch status {
                case .waitingForNetwork: Text(tr("Waiting for a network connection.")).foregroundStyle(.secondary)
                case .serverUnreachable: Text(tr("Can't reach the server.")).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(Localization.locale))
    }
}

/// Keep both the failure list and its live count footer out of the parent observation.
private struct BackupFailedItemsSection: View {
    let model: BackupModel

    var body: some View {
        if !model.failedItems.isEmpty {
            Section {
                ForEach(model.failedItems) { item in
                    HStack(spacing: 12) {
                        Label(item.reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.primary)
                            .symbolRenderingMode(.multicolor)
                        Spacer(minLength: 8)
                        Button(tr("Try Again")) { Task { await model.retry([item.id]) } }
                            .buttonStyle(.borderless)
                            .disabled(model.isWorking)
                    }
                }
                Button(tr("Try All Again")) { Task { await model.retryAll() } }
                    .disabled(model.isWorking)
            } header: {
                Text(tr("Items with Problems"))
            } footer: {
                if model.counts.failed > model.failedItems.count {
                    Text(tr("Showing the first %lld.", Int64(model.failedItems.count)))
                }
            }
        }
    }
}

#Preview("Backup counts") {
    let model = BackupModel.preview(selected: ["recents"])
    List { BackupCountsSection(model: model) }
        .task { await model.load() }
}

#Preview("Backup check") {
    let model = BackupModel.preview(selected: ["recents"])
    List { BackupCheckSection(model: model) }
        .task { await model.load() }
}

#Preview("Backup problems") {
    let model = BackupModel.preview(selected: ["recents"])
    List { BackupFailedItemsSection(model: model) }
        .task { await model.loadPreview(problems: 2) }
}

#Preview("Backup uploading") {
    List {
        Section { BackupUploadRow(progress: UploadProgress(done: 3, total: 15, currentFilename: "IMG_1234.HEIC")) }
        Section { BackupUploadRow(progress: UploadProgress(done: 4, total: 15, currentFilename: nil)) }
    }
}

#Preview("Backup, background status") {
    List {
        BackupBackgroundRows(
            inFlight: 3, lastBackup: .now.addingTimeInterval(-7200), isRedirectBlocked: false, isRefreshOff: true)
    }
}

#Preview("Backup, redirect blocked") {
    List {
        BackupBackgroundRows(inFlight: 0, lastBackup: nil, isRedirectBlocked: true, isRefreshOff: false)
    }
}

#Preview("Backup") {
    NavigationStack { BackupView(model: .preview(selected: ["recents"], excluded: ["screenshots"])) }
}

#Preview("Backup, deleted on server and problems") {
    let model = BackupModel.preview(selected: ["recents"], excluded: ["screenshots"])
    NavigationStack { BackupView(model: model) }
        .task { await model.loadPreview(deletedOnServer: 3, problems: 2) }
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
    func changes() -> AsyncStream<NetworkPath> { AsyncStream { $0.finish() } }
}
